#!/usr/bin/env bash
# Step 3a — Independent k-mer screen with BBTools SendSketch (JGI sketch server).
# A MinHash sketch of the seeded subsample (R1 only; sendsketch has no in2=) is sent to the server and compared
# against the 'nt' and 'refseq' sketch collections. Only the sketch leaves the machine.
# Limitation: a whole-readset sketch is dominated by host k-mers, so low-abundance taxa
# (<~0.1%) are usually invisible here; this is a sanity check, not a sensitive detector.
# Usage: bash scripts/03_sendsketch.sh [RUN ...]
source "$(dirname "$0")/common.sh"
require_tools sendsketch.sh

OUT="$RES_DIR/03_screen/sendsketch"
mkdir -p "$OUT" "$LOG_DIR/03_screen"

for run in ${@:-$RUNS}; do
    is_done "subsample_$run" || die "$run: run step 2 first (subsample)"
    s1="$SUB_DIR/${run}_1.sub${SUB_PAIRS}.s${SEED}.fastq.gz"
    for db in nt refseq; do
        step="sendsketch_${db}_$run"
        is_done "$step" && { log "$run/$db: done, skipping"; continue; }
        log "$run: SendSketch vs $db"
        sendsketch.sh in="$s1" address="$db" \
            records=50 format=3 printdepth=t printdepth2=t minhits=3 \
            out="$OUT/${run}.${db}.tsv" -Xmx1g 2>"$LOG_DIR/03_screen/${run}.sendsketch_${db}.log" \
            || die "$run/$db: sendsketch failed (network?) — see log"
        mark_done "$step"
    done
done
log "Step 3a complete: $OUT"
