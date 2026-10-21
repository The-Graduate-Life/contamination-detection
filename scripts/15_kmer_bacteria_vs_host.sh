#!/usr/bin/env bash
# Step 15 — Read-level test: where do k-mer 'Bacteria' assignments come from?
# STAT assigned 255,756 WGS reads only to domain Bacteria. STAT gives no per-read output, so we
# reproduce the situation with Kraken2 (PlusPF-16, which contains no plant genomes) on ALL trimmed
# pairs, then cross-tabulate Bacteria-assigned fragments against the host classes of step 11.
# If most Bacteria-assigned fragments map confidently/ambiguously to the peanut genome (organelles,
# nuclear plastid/mito insertions), domain-level bacterial k-mer hits are explained by host DNA.
# Usage: bash scripts/15_kmer_bacteria_vs_host.sh RUN
source "$(dirname "$0")/common.sh"
require_tools kraken2 samtools python3

run="${1:?RUN}"; K2="$DB_DIR/kraken2/${K2_DB_NAME:-k2_pluspf_16_GB_20260626}"
O="$RES_DIR/03_screen/kraken2_all/$run"; mkdir -p "$O"
t1="$TRIM_DIR/${run}_1.trim.fastq.gz"; t2="$TRIM_DIR/${run}_2.trim.fastq.gz"

if ! is_done "k2all_$run"; then
    kraken2 --db "$K2" --threads "$THREADS" --paired --gzip-compressed --report "$O/$run.k2report" \
        --output "$O/$run.k2out" "$t1" "$t2" 2> "$O/$run.kraken2.log"
    mark_done "k2all_$run"
fi
# Read IDs: (a) assigned exactly to domain Bacteria (taxid 2, the STAT-like case); (b) anywhere in Bacteria
awk -F'\t' '$1=="C" && $3==2 {print $2}' "$O/$run.k2out" > "$O/ids_domain_only.txt"
python3 - "$O/$run.k2report" "$O/$run.k2out" "$O/ids_bacteria_clade.txt" <<'EOF'
import sys
rep, out, dest = sys.argv[1:4]
# taxa under Bacteria from the report's indentation structure (last two columns: taxid, indented name)
bact, inside, depth0 = set(), False, None
for line in open(rep):
    f = line.rstrip("\n").split("\t")
    name, tax = f[-1], f[-2]
    depth = len(name) - len(name.lstrip(" "))
    if not inside and name.strip() == "Bacteria":
        inside, depth0 = True, depth; bact.add(tax); continue
    if inside:
        if depth <= depth0: inside = False
        else: bact.add(tax)
print(f"taxa under Bacteria: {len(bact)}", file=sys.stderr)
with open(dest, "w") as fo:
    for line in open(out):
        f = line.split("\t", 3)
        if f[0] == "C" and f[2] in bact: fo.write(f[1] + "\n")
EOF
# host class for those fragments (name-sorted primary records from the host BAM)
bam="$RES_DIR/02_host/genome/$run/$run.host.bam"
for set in domain_only bacteria_clade; do
    samtools view -F 0x900 "$bam" | python3 "$ROOT/scripts/lib/host_class_of_ids.py" "$O/ids_$set.txt" NC_037358.1,MW448460.1 "$run" "$set" > "$O/$run.$set.by_host_class.tsv"
    cat "$O/$run.$set.by_host_class.tsv"
done
log "Step 15 complete for $run"
