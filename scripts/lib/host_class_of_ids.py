#!/usr/bin/env python3
"""Host class (step-11 definitions) for a set of read IDs; stdin = host BAM records (samtools view -F 0x900).
args: ids.txt organelle_contigs run setname"""
import sys
from collections import defaultdict, Counter
ids = set(l.strip() for l in open(sys.argv[1])); org = set(sys.argv[2].split(",")); run, setname = sys.argv[3], sys.argv[4]
recs = defaultdict(list)
for line in sys.stdin:
    f = line.split("\t", 6)
    if f[0] in ids: recs[f[0]].append((int(f[1]), f[2], int(f[4])))
c = Counter(); primary_ref = Counter()
for q, rr in recs.items():
    mapped = [(ref, mq) for fl, ref, mq in rr if not fl & 4]
    if not mapped: c["unmapped"] += 1; continue
    conf = [(r, m) for r, m in mapped if m >= 20]
    on_org = any(r in org for r, _ in mapped)
    if conf and any(r not in org for r, _ in conf): k = "nuclear_confident"
    elif conf: k = "organellar_confident"
    else: k = "ambiguous_organelle_primary" if on_org else "ambiguous_nuclear"
    c[k] += 1
n = len(ids)
print("run\tset\thost_class\tfragments\tpct_of_set")
for k, v in c.most_common():
    print(f"{run}\t{setname}\t{k}\t{v}\t{100*v/n:.2f}")
print(f"{run}\t{setname}\tTOTAL_in_set\t{n}\t100.00")
