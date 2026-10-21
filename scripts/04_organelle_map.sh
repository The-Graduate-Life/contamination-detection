#!/usr/bin/env bash
# Step 4 — Map trimmed reads to the A. hypogaea chloroplast (NC_037358.1) and mitochondrion (MW448460.1).
# Purpose: quantify the organelle-like fraction and test whether STAT's domain-level "Bacteria"
# reads in the WGS run are organellar (plastid/mito rRNA and genes are bacteria-derived).
# Caveat: without the nuclear genome in the index, nuclear organelle-derived copies (NUPTs/NUMTs)
# also land here, so counts are "organelle-like", not proof of organellar origin. Plastid DNA
# inserted in the mitogenome (MTPTs) gives low MAPQ between the two references.
# Counting unit: read pair (fragment). Denominator: trimmed pairs analysed.
# Usage: bash scripts/04_organelle_map.sh [RUN ...]
source "$(dirname "$0")/common.sh"
require_tools bowtie2 bowtie2-build samtools

REF="$REF_DIR/organelles/organelles.fasta"
IDX="$REF_DIR/organelles/bt2/organelles"
OUT="$RES_DIR/02_host/organelles"
mkdir -p "$OUT" "$(dirname "$IDX")" "$LOG_DIR/04_organelle"

if ! is_done organelle_index; then
    fetch_organelles
    cat "$REF_DIR/organelles/NC_037358.1.fasta" "$REF_DIR/organelles/MW448460.1.fasta" > "$REF"
    bowtie2-build --threads "$THREADS" "$REF" "$IDX" > "$LOG_DIR/04_organelle/bowtie2-build.log" 2>&1
    samtools faidx "$REF"
    mark_done organelle_index
fi

for run in ${@:-$RUNS}; do
    is_done "fastp_$run" || die "$run: run step 2 first"
    step="organelle_map_$run"
    is_done "$step" && { log "$run: organelle mapping done, skipping"; continue; }
    t1="$TRIM_DIR/${run}_1.trim.fastq.gz"; t2="$TRIM_DIR/${run}_2.trim.fastq.gz"
    bam="$OUT/$run.organelles.bam"

    # End-to-end, default sensitivity; keep only pairs with >=1 mapped mate (--no-unal) to keep BAM small.
    log "$run: bowtie2 -> organelles"
    bowtie2 -p "$THREADS" -x "$IDX" -1 "$t1" -2 "$t2" -X 800 --no-unal \
        2> "$OUT/$run.bowtie2.log" \
        | samtools sort -@ 2 -m 512M -o "$bam.tmp" -
    mv "$bam.tmp" "$bam"; samtools index "$bam"

    total=$(awk -F'\t' -v r="$run" '$1==r{print $3}' "$RES_DIR/01_qc/retention.tsv")
    [[ -n $total ]] || die "$run: trimmed pair count not found in retention.tsv"

    # Fragment counts (count R1 or, if R1 unmapped, R2 — one record per fragment; primary only)
    frag() { samtools view -c -F 0x900 "$@" "$bam"; }
    any=$(( $(frag -f 0x40 -F 0x4) + $(frag -f 0x88 -F 0x4) ))            # >=1 mate mapped
    conc=$(frag -f 0x42)                                                  # properly paired
    q20=$(( $(frag -f 0x40 -F 0x4 -q 20) + $(frag -f 0x88 -F 0x4 -q 20) ))
    per_ref() {  # fragments per reference, >=1 mate mapped, given MAPQ threshold
        { samtools view -F 0x904 -f 0x40 -q "$2" "$bam" "$1"; samtools view -F 0x904 -f 0x88 -q "$2" "$bam" "$1"; } | wc -l; }
    cp_all=$(per_ref NC_037358.1 0); mt_all=$(per_ref MW448460.1 0)
    cp_q20=$(per_ref NC_037358.1 20); mt_q20=$(per_ref MW448460.1 20)

    {
        printf 'run\tmetric\tfragments\tpct_of_trimmed_pairs\n'
        for m in "trimmed_pairs:$total" "organelle_any:$any" "organelle_proper_pair:$conc" "organelle_mapq20:$q20" \
                 "chloroplast_any:$cp_all" "chloroplast_mapq20:$cp_q20" "mitochondrion_any:$mt_all" "mitochondrion_mapq20:$mt_q20"; do
            k=${m%%:*}; v=${m##*:}
            awk -v r="$run" -v k="$k" -v v="$v" -v t="$total" 'BEGIN{printf "%s\t%s\t%d\t%.4f\n", r, k, v, 100*v/t}'
        done
    } > "$OUT/$run.organelle_counts.tsv"

    # Depth/breadth per organelle (MAPQ>=20, base Q>=20, duplicates kept)
    samtools coverage -q 20 -Q 20 "$bam" > "$OUT/$run.coverage_q20.tsv"
    samtools coverage "$bam" > "$OUT/$run.coverage_all.tsv"
    samtools idxstats "$bam" > "$OUT/$run.idxstats.tsv"
    mark_done "$step"
    log "$run: $any of $total pairs organelle-like ($q20 at MAPQ>=20)"
done
log "Step 4 complete: $OUT"
