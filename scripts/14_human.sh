#!/usr/bin/env bash
# Step 14 — Validate the Kraken2 'Homo sapiens' signal in a run's NON-HOST POOL.
# Non-host pairs -> Bowtie2 end-to-end --sensitive vs GRCh38 (Langmead lab prebuilt
# GRCh38_full_as index: primary assembly + chrM + unplaced/unlocalised, no alt contigs).
# Reported: pairs aligned, MAPQ>=20, identity >=0.98 ('human-confident'), chrM share, spread across
# chromosomes. High identity + MAPQ is needed because conserved eukaryotic genes from other
# organisms in the pool (e.g. the abundant Fusarium) can align to human at lower identity.
# Usage: bash scripts/14_human.sh download | RUN
source "$(dirname "$0")/common.sh"
require_tools bowtie2 samtools python3

HG="$DB_DIR/human/GRCh38_full_as"
if [[ ${1:?usage} == download ]]; then
    mkdir -p "$(dirname "$HG")"
    for s in 1 2 3 4 rev.1 rev.2; do
        wget -q -c -O "$HG.$s.bt2" "https://genome-idx.s3.amazonaws.com/bt/GRCh38_full_as.$s.bt2" || die "download $s failed"
    done
    printf 'index\tsource\tdownloaded\nGRCh38_full_as\thttps://genome-idx.s3.amazonaws.com/bt/\t%s\n' "$(date +%F)" > "$HG.VERSION.tsv"
    exit 0
fi

run="$1"; O="$RES_DIR/04_validation/human/$run"; mkdir -p "$O"
[[ -s $HG.1.bt2 ]] || die "GRCh38 index missing: run '$0 download'"
is_done "hostpart_$run" || die "$run: run step 11 first"
total=$(awk -F'\t' -v r="$run" '$1==r{print $3}' "$RES_DIR/01_qc/retention.tsv")
pool=$(awk -F'\t' '$2=="nonhost_pool_fastq_pairs"{print $3}' "$RES_DIR/02_host/genome/$run/$run.host_partition.tsv")

if ! is_done "human_$run"; then
    bowtie2 -p "$THREADS" --sensitive -x "$HG" -1 "$DATA_DIR/nonhost/${run}_nonhost_1.fq.gz" \
        -2 "$DATA_DIR/nonhost/${run}_nonhost_2.fq.gz" -X 800 --no-unal 2> "$O/$run.bowtie2.log" \
      | samtools sort -@ 4 -o "$O/$run.human.bam" -
    samtools index "$O/$run.human.bam"
    mark_done "human_$run"
fi
samtools idxstats "$O/$run.human.bam" > "$O/$run.idxstats.tsv"
# one record per fragment (R1, or R2 if R1 unmapped), primary
{ samtools view -F 0x904 -f 0x40 "$O/$run.human.bam"; samtools view -F 0x904 -f 0x88 "$O/$run.human.bam"; } \
  | python3 "$ROOT/scripts/lib/human_summary.py" "$run" "$total" "$pool" > "$O/$run.human_summary.tsv"
cat "$O/$run.human_summary.tsv"
log "Step 14 complete for $run"
