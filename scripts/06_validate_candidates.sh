#!/usr/bin/env bash
# Step 6 — Competitive validation of screening candidates (config/validation_panel.tsv).
#
# Stage A (competitive assignment): trimmed pairs -> Bowtie2 --local against the whole panel
#   (candidates + close competitors + host decoy: A. hypogaea RefSeq transcripts + organelles).
#   Each fragment is assigned to the label/group of its primary alignment. Fragments assigned to
#   the host decoy are host-like; a candidate is supported only by fragments that beat the decoy.
#   MAPQ>=20 = unambiguous within the WHOLE panel (low MAPQ within a group of near-identical
#   isolates is expected and does not argue against the group).
# Stage B (coverage): fragments assigned to a candidate group are realigned to the group's
#   best-supported reference alone; samtools coverage gives mean depth and breadth.
#
# Counting unit: fragment (read pair; the mate with the higher alignment score). Denominators:
#   pct_trimmed        = fragments / trimmed pairs analysed
#   pct_candidate_hits = fragments / fragments assigned to any non-decoy panel group
#   (the true non-host-pool fraction needs nuclear host mapping, done later on HPC)
# Usage: [PANEL=name] bash scripts/06_validate_candidates.sh RUN [full|sub|nonhost]
#   sub     = 500k-pair test subsample
#   nonhost = the run's non-host pool from step 11 (pct_trimmed still uses all trimmed pairs)
#   PANEL   = optional panel name -> config/validation_panel_<name>.tsv, references/validation_<name>
source "$(dirname "$0")/common.sh"
require_tools bowtie2 bowtie2-build samtools python3

run="${1:?usage: 06_validate_candidates.sh RUN [full|sub|nonhost]}"
mode="${2:-full}"
sfx="${PANEL:+_$PANEL}"
VDIR="$REF_DIR/validation$sfx"
IDX="$VDIR/bt2/panel"
is_done "validation_refs$sfx" || die "run step 5 first (PANEL='${PANEL:-}')"

if [[ $mode == sub ]]; then
    r1="$SUB_DIR/${run}_1.sub${SUB_PAIRS}.s${SEED}.fastq.gz"; r2="$SUB_DIR/${run}_2.sub${SUB_PAIRS}.s${SEED}.fastq.gz"
    total=$SUB_PAIRS; tag="${run}.sub"
elif [[ $mode == nonhost ]]; then
    is_done "hostpart_$run" || die "$run: run step 11 first"
    r1="$DATA_DIR/nonhost/${run}_nonhost_1.fq.gz"; r2="$DATA_DIR/nonhost/${run}_nonhost_2.fq.gz"
    total=$(awk -F'\t' -v r="$run" '$1==r{print $3}' "$RES_DIR/01_qc/retention.tsv"); tag="${run}.nonhost$sfx"
else
    r1="$TRIM_DIR/${run}_1.trim.fastq.gz"; r2="$TRIM_DIR/${run}_2.trim.fastq.gz"
    total=$(awk -F'\t' -v r="$run" '$1==r{print $3}' "$RES_DIR/01_qc/retention.tsv"); tag="$run"
fi
[[ -n $total ]] || die "$run: cannot determine analysed pair count"
OUT="$RES_DIR/04_validation/$tag"
mkdir -p "$OUT" "$(dirname "$IDX")" "$LOG_DIR/06_validation"

# ---- index (once) ----
if ! is_done "panel_index$sfx"; then
    log "bowtie2-build panel ($(awk 'NR==2{print $5}' "$VDIR/panel.stats.tsv") bp)"
    bowtie2-build --threads "$THREADS" "$VDIR/panel.fasta" "$IDX" > "$LOG_DIR/06_validation/bowtie2-build.log" 2>&1
    samtools faidx "$VDIR/panel.fasta"
    mark_done "panel_index$sfx"
fi

# ---- Stage A ----
bam="$OUT/$tag.panel.bam"
if ! is_done "validateA_$tag"; then
    log "$tag: Stage A bowtie2 --local vs panel"
    bowtie2 -p "$THREADS" --local -x "$IDX" -1 "$r1" -2 "$r2" -X 800 --no-unal \
        2> "$OUT/$tag.stageA.bowtie2.log" \
        | samtools view -b -F 0x100 - | samtools sort -@ 2 -m 512M -o "$bam.tmp" -
    mv "$bam.tmp" "$bam"; samtools index "$bam"
    mark_done "validateA_$tag"
fi

# Per-fragment assignment table (primary records only): fragment, label, group, MAPQ, identity
if ! is_done "assign_$tag"; then
    samtools view -F 0x904 "$bam" | python3 "$ROOT/scripts/lib/assign_fragments.py" \
        "$VDIR/contig_map.tsv" "$total" "$OUT/$tag.fragments.tsv.gz" "$OUT/$tag.assignment_summary.tsv" \
        "$OUT/$tag.group_summary.tsv"
    mark_done "assign_$tag"
fi

# ---- Stage B: per candidate group, realign assigned fragments to the best label ----
if ! is_done "validateB_$tag"; then
    python3 - "$OUT/$tag.group_summary.tsv" > "$OUT/$tag.best_labels.tsv" <<'EOF'
import sys, csv
for r in csv.DictReader(open(sys.argv[1]), delimiter="\t"):
    if r["group"] != "host_decoy" and int(r["fragments"]) > 0:
        print(r["group"], r["best_label"], sep="\t")
EOF
    printf 'group\tlabel\tcontig\tlength\tnumreads\tcovbases\tbreadth_1x_pct\tmeandepth\tmeanbaseq\tmeanmapq\tbreadth_5x_pct\tbreadth_10x_pct\tstageB_fragments\tstageB_mean_identity\n' > "$OUT/$tag.coverage.tsv"
    while IFS=$'\t' read -r group label; do
        gdir="$OUT/stageB/$group"; mkdir -p "$gdir"
        # fragment names assigned to this group in Stage A
        zcat "$OUT/$tag.fragments.tsv.gz" | awk -F'\t' -v g="$group" '$3==g{print $1}' > "$gdir/names.txt"
        samtools view -b -N "$gdir/names.txt" "$bam" | samtools collate -O -u - \
            | samtools fastq -1 "$gdir/r1.fq.gz" -2 "$gdir/r2.fq.gz" -0 /dev/null -s "$gdir/single.fq.gz" -n - 2>/dev/null
        ref="$gdir/$label.fasta"
        awk -F'\t' -v l="$label" '$4==l{print $1}' "$VDIR/contig_map.tsv" > "$gdir/contigs.txt"
        samtools faidx "$VDIR/panel.fasta" -r "$gdir/contigs.txt" > "$ref"
        bowtie2-build -q "$ref" "$gdir/idx"
        bowtie2 -p "$THREADS" --local -x "$gdir/idx" -1 "$gdir/r1.fq.gz" -2 "$gdir/r2.fq.gz" -X 800 --no-unal \
            2> "$gdir/stageB.bowtie2.log" | samtools sort -@ 2 -o "$gdir/$label.bam" -
        samtools index "$gdir/$label.bam"
        # Coverage per contig (MAPQ>=0 here: single-reference realignment) then aggregated per label
        samtools coverage "$gdir/$label.bam" > "$gdir/coverage.tsv"
        samtools depth -a "$gdir/$label.bam" > "$gdir/depth.tsv"
        python3 "$ROOT/scripts/lib/summarise_coverage.py" "$group" "$label" "$gdir/coverage.tsv" \
            "$gdir/depth.tsv" "$gdir/$label.bam" >> "$OUT/$tag.coverage.tsv"
        rm -f "$gdir/depth.tsv"
    done < "$OUT/$tag.best_labels.tsv"
    mark_done "validateB_$tag"
fi
log "Step 6 complete for $tag: $OUT"
