#!/usr/bin/env bash
# Step 1 — Download paired FASTQ from the ENA mirror and verify integrity.
#   * MD5 of each file vs. ENA filereport (metadata/ena_filereport.tsv)
#   * read counts vs. SRA spots (metadata/sra_runinfo.csv)
#   * pair synchronisation: read IDs must match line-by-line between R1 and R2
# Raw files are made read-only after verification and never modified afterwards.
# Usage: bash scripts/01_download_verify.sh [RUN ...]   (default: both runs)
source "$(dirname "$0")/common.sh"
require_tools wget md5sum seqkit awk

OUT="$RES_DIR/00_verify"
mkdir -p "$RAW_DIR" "$OUT" "$LOG_DIR/01_download"
REPORT="$META_DIR/ena_filereport.tsv"
RUNINFO="$META_DIR/sra_runinfo.csv"
[[ -s $REPORT && -s $RUNINFO ]] || die "metadata tables missing in $META_DIR"

# column lookup by header name in the ENA TSV
ena_field() { awk -F'\t' -v run="$1" -v col="$2" 'NR==1{for(i=1;i<=NF;i++)h[$i]=i; next} $1==run{print $h[col]}' "$REPORT"; }
sra_spots() { awk -F',' -v run="$1" 'NR==1{for(i=1;i<=NF;i++)h[$i]=i; next} $1==run{print $h["spots"]}' "$RUNINFO"; }

for run in ${@:-$RUNS}; do
    step="download_$run"
    if is_done "$step"; then log "$run: already downloaded and verified, skipping"; continue; fi

    IFS=';' read -ra urls <<< "$(ena_field "$run" fastq_ftp)"
    IFS=';' read -ra md5s <<< "$(ena_field "$run" fastq_md5)"
    [[ ${#urls[@]} -eq 2 ]] || die "$run: expected 2 FASTQ files (paired), got ${#urls[@]}"

    for i in 0 1; do
        f="$RAW_DIR/$(basename "${urls[$i]}")"
        if [[ ! -f $f ]] || [[ -w $f ]]; then          # resumable; read-only files are already verified
            log "$run: downloading ${urls[$i]}"
            wget -c -q --tries=5 -O "$f" "https://${urls[$i]}" 2>>"$LOG_DIR/01_download/$run.wget.log" \
                || die "$run: download failed (see $LOG_DIR/01_download/$run.wget.log)"
        fi
        got=$(md5sum "$f" | cut -d' ' -f1)
        [[ $got == "${md5s[$i]}" ]] || die "$run: MD5 mismatch for $f (got $got, expected ${md5s[$i]}); delete and re-run"
        log "$run: MD5 OK $(basename "$f")"
        printf '%s  %s\n' "$got" "$f" >> "$OUT/checksums.md5"
    done

    r1="$RAW_DIR/${run}_1.fastq.gz"; r2="$RAW_DIR/${run}_2.fastq.gz"
    seqkit stats --quiet -a -T -j 2 "$r1" "$r2" > "$OUT/${run}.seqkit_stats.tsv"
    n1=$(awk -F'\t' 'NR==2{print $4}' "$OUT/${run}.seqkit_stats.tsv")
    n2=$(awk -F'\t' 'NR==3{print $4}' "$OUT/${run}.seqkit_stats.tsv")
    spots=$(sra_spots "$run")
    [[ $n1 == "$spots" && $n2 == "$spots" ]] || die "$run: read count mismatch (R1=$n1 R2=$n2 SRA spots=$spots)"

    # Pair synchronisation: compare read IDs (strip /1 /2 and comments) line by line
    mism=$(paste <(seqkit seq -n -i "$r1") <(seqkit seq -n -i "$r2") \
        | awk '{a=$1; b=$2; sub(/\/[12]$/,"",a); sub(/\/[12]$/,"",b); if(a!=b) n++} END{print n+0}')
    [[ $mism -eq 0 ]] || die "$run: $mism read-ID mismatches between R1 and R2"
    log "$run: $n1 pairs, counts match SRA, R1/R2 IDs synchronised"
    printf '%s\t%s\t%s\t%s\t%s\n' "$run" "$spots" "$n1" "$n2" "$mism" >> "$OUT/read_counts.tsv.tmp"

    chmod a-w "$r1" "$r2"        # preserve raw reads unchanged
    mark_done "$step"
done

# Assemble summary table (header + one row per verified run, de-duplicated)
if [[ -f "$OUT/read_counts.tsv.tmp" ]]; then
    { printf 'run\tsra_spots\tR1_reads\tR2_reads\tid_mismatches\n'
      { [[ -f "$OUT/read_counts.tsv" ]] && tail -n +2 "$OUT/read_counts.tsv"; cat "$OUT/read_counts.tsv.tmp"; } | sort -u; } > "$OUT/read_counts.tsv.new"
    mv "$OUT/read_counts.tsv.new" "$OUT/read_counts.tsv"; rm -f "$OUT/read_counts.tsv.tmp"
    sort -u -k2 "$OUT/checksums.md5" -o "$OUT/checksums.md5"
fi
log "Step 1 complete: $OUT/read_counts.tsv"
