#!/usr/bin/env bash
# Step 2 — Raw QC, conservative trimming, post-trim QC, seeded paired subsample.
#   FastQC (raw) -> fastp (adapters, poly-G, sliding-window Q, min length; NO dedup)
#   -> FastQC (trimmed) -> MultiQC -> seqtk paired subsample (same seed for R1/R2)
# Usage: bash scripts/02_qc_trim_subsample.sh [RUN ...]
source "$(dirname "$0")/common.sh"
require_tools fastqc fastp multiqc seqtk seqkit pigz

OUT="$RES_DIR/01_qc"
mkdir -p "$OUT"/{fastqc_raw,fastqc_trimmed,fastp} "$TRIM_DIR" "$SUB_DIR" "$LOG_DIR/02_qc"

for run in ${@:-$RUNS}; do
    is_done "download_$run" || die "$run: run step 1 first"
    r1="$RAW_DIR/${run}_1.fastq.gz"; r2="$RAW_DIR/${run}_2.fastq.gz"
    t1="$TRIM_DIR/${run}_1.trim.fastq.gz"; t2="$TRIM_DIR/${run}_2.trim.fastq.gz"

    if ! is_done "fastqc_raw_$run"; then
        log "$run: FastQC raw"
        fastqc -q -t 2 -o "$OUT/fastqc_raw" "$r1" "$r2" 2>"$LOG_DIR/02_qc/$run.fastqc_raw.log"
        mark_done "fastqc_raw_$run"
    fi

    if ! is_done "fastp_$run"; then
        log "$run: fastp (Q$FASTP_QUAL cut_right, minlen $FASTP_MINLEN, adapter PE detection, poly-G)"
        # temp names must end in .gz: fastp chooses gzip output from the extension
        fastp -i "$r1" -I "$r2" -o "${t1%.fastq.gz}.tmp.fastq.gz" -O "${t2%.fastq.gz}.tmp.fastq.gz" \
            --detect_adapter_for_pe --trim_poly_g \
            --cut_right --cut_right_window_size 4 --cut_right_mean_quality "$FASTP_QUAL" \
            --length_required "$FASTP_MINLEN" --n_base_limit 5 \
            --thread "$THREADS" \
            --json "$OUT/fastp/$run.fastp.json" --html "$OUT/fastp/$run.fastp.html" \
            2>"$LOG_DIR/02_qc/$run.fastp.log"
        mv "${t1%.fastq.gz}.tmp.fastq.gz" "$t1"; mv "${t2%.fastq.gz}.tmp.fastq.gz" "$t2"
        pigz -t "$t1" "$t2" || die "$run: trimmed output is not valid gzip"
        mark_done "fastp_$run"
    fi

    if ! is_done "fastqc_trim_$run"; then
        log "$run: FastQC trimmed"
        fastqc -q -t 2 -o "$OUT/fastqc_trimmed" "$t1" "$t2" 2>"$LOG_DIR/02_qc/$run.fastqc_trim.log"
        mark_done "fastqc_trim_$run"
    fi

    if ! is_done "subsample_$run"; then
        log "$run: subsample $SUB_PAIRS pairs (seqtk seed $SEED) from trimmed reads"
        for r in 1 2; do
            seqtk sample -2 -s "$SEED" "$TRIM_DIR/${run}_${r}.trim.fastq.gz" "$SUB_PAIRS" \
                | pigz -p 2 > "$SUB_DIR/${run}_${r}.sub${SUB_PAIRS}.s${SEED}.fastq.gz"
        done
        seqkit stats -T "$SUB_DIR/${run}"_*.sub"${SUB_PAIRS}".s"${SEED}".fastq.gz > "$OUT/${run}.subsample_stats.tsv"
        mark_done "subsample_$run"
    fi
done

multiqc -q -f -o "$OUT" -n multiqc_report.html "$OUT" 2>"$LOG_DIR/02_qc/multiqc.log"

# Retention table from fastp JSON (counts are reads; pairs = reads / 2)
python3 - "$OUT" <<'EOF'
import json, glob, os, sys
out = sys.argv[1]
rows = ["run\tpairs_before\tpairs_after\tpct_pairs_retained\tbases_before\tbases_after\tpct_bases_retained\tq30_before\tq30_after\tadapter_trimmed_reads\tdup_rate_est"]
for f in sorted(glob.glob(f"{out}/fastp/*.fastp.json")):
    d = json.load(open(f)); s = d["summary"]; b, a = s["before_filtering"], s["after_filtering"]
    run = os.path.basename(f).split(".")[0]
    rows.append("\t".join(map(str, [run, b["total_reads"]//2, a["total_reads"]//2,
        f"{100*a['total_reads']/b['total_reads']:.2f}", b["total_bases"], a["total_bases"],
        f"{100*a['total_bases']/b['total_bases']:.2f}", f"{b['q30_rate']:.4f}", f"{a['q30_rate']:.4f}",
        d.get("adapter_cutting", {}).get("adapter_trimmed_reads", 0), f"{d.get('duplication', {}).get('rate', 0):.4f}"])))
open(f"{out}/retention.tsv", "w").write("\n".join(rows) + "\n")
print("\n".join(rows))
EOF
log "Step 2 complete: $OUT/multiqc_report.html, $OUT/retention.tsv"
