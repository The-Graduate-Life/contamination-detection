#!/usr/bin/env bash
# Step 8 — Per-protein comparison of the assembled polerovirus contig with CPPV2 and close relatives.
# Each annotated reference protein (GenBank CDS translations) is aligned to the contig with tblastn;
# reported: % amino-acid identity, aligned length, % of the reference protein covered.
# This supplies the evidence for a species-level judgement (ICTV Polerovirus criteria refer to
# amino-acid differences in gene products); the judgement itself is left to the user.
# Usage: bash scripts/08_polerovirus_orfs.sh RUN CONTIG_ID
source "$(dirname "$0")/common.sh"
require_tools efetch tblastn seqkit

run="${1:?RUN}"; contig="${2:?CONTIG_ID}"
D="$RES_DIR/05_virus/$run/polerovirus_orfs"; mkdir -p "$D/refs"
# Reference genomes: CPPV2 plus the closest relatives seen in DIAMOND/panel results
REFS="NC_034247.1 NC_117245.1 NC_028793.2 NC_008249.1 NC_076825.1 LC818997.1 NC_015050.1 NC_003688.1"

seqkit grep -p "$contig" "$RES_DIR/05_virus/$run/contigs.fa" > "$D/$contig.fa"
[[ -s "$D/$contig.fa" ]] || die "contig $contig not found"

printf 'reference\tprotein_id\tprotein\tprotein_len\tpident\taln_len\tpct_protein_covered\tcontig_start\tcontig_end\tevalue\n' > "$D/per_protein_identity.tsv"
for acc in $REFS; do
    f="$D/refs/$acc.cds_aa.faa"
    [[ -s $f ]] || efetch -db nuccore -id "$acc" -format fasta_cds_aa > "$f" 2>>"$LOG_DIR/07_virus/efetch_cds.log"
    grep -q '^>' "$f" || { log "WARN: no CDS annotation for $acc"; continue; }
    tblastn -query "$f" -subject "$D/$contig.fa" -evalue 1e-5 -seg no \
        -outfmt "6 qseqid qlen pident length sstart send evalue bitscore" \
      | sort -k1,1 -k8,8gr | awk '!s[$1]++' > "$D/refs/$acc.tblastn.tsv"
    # map protein_id -> protein name from the FASTA headers
    python3 - "$f" "$D/refs/$acc.tblastn.tsv" "$acc" >> "$D/per_protein_identity.tsv" <<'EOF'
import re, sys
faa, hits, acc = sys.argv[1:4]
names, lens, order = {}, {}, []
cur = None
for line in open(faa):
    if line.startswith(">"):
        cur = line[1:].split()[0]; order.append(cur)
        m = re.search(r"\[protein=([^\]]+)\]", line); names[cur] = m.group(1) if m else "NA"; lens[cur] = 0
    else:
        lens[cur] += len(line.strip())
best = {}
for l in open(hits):
    q, qlen, pid, alen, s, e, ev, bs = l.rstrip("\n").split("\t"); best[q] = (pid, int(alen), s, e, ev)
for q in order:
    pid = re.search(r"prot_([^_]+_[^_]+)", q); pid = pid.group(1) if pid else q
    if q in best:
        p, alen, s, e, ev = best[q]
        print(acc, pid, names[q], lens[q], p, alen, f"{100*min(alen, lens[q])/lens[q]:.1f}", s, e, ev, sep="\t")
    else:
        print(acc, pid, names[q], lens[q], "NA", 0, "0.0", "NA", "NA", "NA", sep="\t")
EOF
done
log "Step 8 complete: $D/per_protein_identity.tsv"
