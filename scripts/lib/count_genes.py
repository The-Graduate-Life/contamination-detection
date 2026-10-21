#!/usr/bin/env python3
"""Count fragments per annotated gene (GFF3 'gene' features; product taken from child CDS/rRNA/tRNA).

stdin : SAM records, one per fragment
args  : genes.gff3  out_counts.tsv  out_summary.tsv  run group label stratum min_id
A fragment is assigned to the gene overlapping its alignment start (first gene found if overlapping);
fragments outside genes are 'intergenic'. Summary reports distinct genes hit (>=1 and >=5 fragments)
and the share of fragments on rRNA genes (a conserved locus prone to cross-mapping).
"""
import bisect, sys
from collections import defaultdict

gff, out_counts, out_sum, run, group, label, stratum, min_id = sys.argv[1:9]
genes = {}                      # id -> [contig, start, end, biotype, product, locus]
parent_of = {}
for line in open(gff):
    if line.startswith("#"): continue
    f = line.rstrip("\n").split("\t")
    if len(f) < 9: continue
    attrs = dict(kv.split("=", 1) for kv in f[8].split(";") if "=" in kv)
    if f[2] in ("gene", "pseudogene"):
        genes[attrs.get("ID")] = [f[0], int(f[3]), int(f[4]), attrs.get("gene_biotype", f[2]), "", attrs.get("locus_tag", attrs.get("Name", ""))]
    elif "Parent" in attrs:
        parent_of[attrs.get("ID", "")] = attrs["Parent"]
        p = attrs["Parent"]
        while p in parent_of and p not in genes: p = parent_of[p]
        if p in genes and not genes[p][4]:
            genes[p][4] = attrs.get("product", "")

by_contig = defaultdict(list)
for gid, (c, s, e, bt, prod, loc) in genes.items():
    by_contig[c].append((s, e, gid))
starts = {}
for c in by_contig:
    by_contig[c].sort(); starts[c] = [x[0] for x in by_contig[c]]

counts = defaultdict(int); total = 0
for line in sys.stdin:
    f = line.split("\t"); c, pos = f[2], int(f[3]); total += 1
    hit = "intergenic"
    if c in by_contig:
        i = bisect.bisect_right(starts[c], pos) - 1
        # check a few preceding genes (overlapping annotations)
        for j in range(max(0, i - 5), i + 1):
            s, e, gid = by_contig[c][j]
            if s <= pos <= e: hit = gid; break
    counts[hit] += 1

with open(out_counts, "w") as fo:
    fo.write("gene_id\tlocus\tbiotype\tproduct\tcontig\tstart\tend\tfragments\n")
    for gid, n in sorted(counts.items(), key=lambda kv: -kv[1]):
        if gid == "intergenic":
            fo.write(f"intergenic\t\t\t\t\t\t\t{n}\n"); continue
        c, s, e, bt, prod, loc = genes[gid]
        fo.write(f"{gid}\t{loc}\t{bt}\t{prod}\t{c}\t{s}\t{e}\t{n}\n")

g1 = sum(1 for g, n in counts.items() if g != "intergenic" and n >= 1)
g5 = sum(1 for g, n in counts.items() if g != "intergenic" and n >= 5)
rrna = sum(n for g, n in counts.items() if g != "intergenic" and genes[g][3] == "rRNA")
with open(out_sum, "w") as fo:
    fo.write("run\tgroup\tlabel\tstratum\tmin_identity\tfragments_realigned\tgenes_annotated\tgenes_ge1\tgenes_ge5\tpct_fragments_rRNA\tpct_fragments_intergenic\n")
    pct = lambda x: f"{100*x/total:.2f}" if total else "NA"
    fo.write("\t".join(map(str, [run, group, label, stratum, min_id, total, len(genes), g1, g5, pct(rrna), pct(counts.get('intergenic', 0))])) + "\n")
print(open(out_sum).read(), end="", file=sys.stderr)
