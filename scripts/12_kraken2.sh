#!/usr/bin/env bash
# Step 12 — Kraken2 + Bracken screen of the NON-HOST POOL (pairs with both mates unmapped to host).
# Database: Kraken2 PlusPF capped at 16 GB (RefSeq archaea, bacteria, viral, plasmid, human,
# UniVec_Core, protozoa, fungi; Langmead lab build). Plants are NOT in PlusPF, which is why
# host reads must be removed first. The 16 GB cap subsamples minimizers -> lower sensitivity
# than the full database; assignments are hypotheses for validation, not detections.
# Usage: bash scripts/12_kraken2.sh download          (login node: ~12 GB download)
#        bash scripts/12_kraken2.sh RUN [READ_LEN]    (compute node: >=20 GB RAM)
source "$(dirname "$0")/common.sh"
require_tools kraken2 bracken

K2_DB_NAME="${K2_DB_NAME:-k2_pluspf_16_GB_20260626}"
K2="$DB_DIR/kraken2/$K2_DB_NAME"

if [[ ${1:?usage} == download ]]; then
    mkdir -p "$K2"
    url="https://genome-idx.s3.amazonaws.com/kraken/$K2_DB_NAME.tar.gz"
    [[ -s $K2/hash.k2d ]] || { wget -q -c -O "$K2.tar.gz" "$url" && tar -xzf "$K2.tar.gz" -C "$K2" && rm -f "$K2.tar.gz"; } \
        || die "Kraken2 DB download/extract failed"
    printf 'database\turl\tdownloaded\n%s\t%s\t%s\n' "$K2_DB_NAME" "$url" "$(date +%F)" > "$K2/VERSION.tsv"
    ls -la "$K2" > "$K2/listing.txt"
    exit 0
fi

run="$1"; rlen="${2:-150}"
[[ -s $K2/hash.k2d ]] || die "Kraken2 DB missing: run '$0 download' first"
p1="$DATA_DIR/nonhost/${run}_nonhost_1.fq.gz"; p2="$DATA_DIR/nonhost/${run}_nonhost_2.fq.gz"
is_done "hostpart_$run" || die "$run: run step 11 first"
O="$RES_DIR/03_screen/kraken2/$run"; mkdir -p "$O"

if ! is_done "kraken2_$run"; then
    kraken2 --db "$K2" --threads "$THREADS" --paired --gzip-compressed \
        --report "$O/$run.k2report" --report-minimizer-data --output "$O/$run.k2out" \
        "$p1" "$p2" 2> "$O/$run.kraken2.log"
    gzip -f "$O/$run.k2out"
    mark_done "kraken2_$run"
fi
# Bracken needs a kmer distribution built for the read length; PlusPF ships 50..300 bp files.
avail=$(ls "$K2"/database*mers.kmer_distrib 2>/dev/null | sed -E 's/.*database([0-9]+)mers.*/\1/' | sort -n)
blen=$(for l in $avail; do echo "$l"; done | awk -v r="$rlen" '{d=($1>r)?$1-r:r-$1; if(b==""||d<bd){b=$1;bd=d}} END{print b}')  # nearest length
if [[ -n $blen ]] && ! is_done "bracken_$run"; then
    for lvl in S G; do
        bracken -d "$K2" -i "$O/$run.k2report" -o "$O/$run.bracken_$lvl.tsv" -w "$O/$run.bracken_$lvl.report" \
            -r "$blen" -l "$lvl" -t 10 > "$O/$run.bracken_$lvl.log" 2>&1
    done
    echo "bracken read length: $blen (reads $rlen)" > "$O/$run.bracken_params.txt"
    mark_done "bracken_$run"
fi
log "Step 12 complete for $run: $O"
