#!/usr/bin/env python3
"""Summarise human (GRCh38) alignments of a non-host pool; stdin = one SAM record per fragment.
args: run total_trimmed_pairs nonhost_pool_pairs"""
import re, sys
from collections import Counter
run, total, pool = sys.argv[1], int(sys.argv[2]), int(sys.argv[3])
CIG = re.compile(r"(\d+)([MIDNSHP=X])")
n = q20 = conf = mt = 0; chroms = Counter()
for line in sys.stdin:
    f = line.split("\t"); mapq = int(f[4])
    nm = next((int(t[5:]) for t in f[11:] if t.startswith("NM:i:")), 0)
    cols = sum(int(k) for k, op in CIG.findall(f[5]) if op in "M=XID")
    ident = (cols - nm) / cols if cols else 0
    n += 1; q20 += mapq >= 20
    if mapq >= 20 and ident >= 0.98:
        conf += 1; chroms[f[2]] += 1; mt += f[2] == "chrM"
nuc = {c for c in chroms if c != "chrM"}
print("run\tmetric\tfragments\tpct_trimmed\tpct_nonhost_pool")
for k, v in [("aligned", n), ("mapq20", q20), ("human_confident_mapq20_id98", conf), ("confident_on_chrM", mt)]:
    print(f"{run}\t{k}\t{v}\t{100*v/total:.5f}\t{100*v/pool:.4f}")
print(f"{run}\tconfident_distinct_nuclear_sequences\t{len(nuc)}\tNA\tNA")
