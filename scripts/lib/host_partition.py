#!/usr/bin/env python3
"""Classify read pairs from a name-sorted SAM stream (primary records only) into host classes.

args: run total_pairs organelle_contigs(comma-separated)
Classes (one per fragment; see scripts/11_host_map.sh):
  nuclear_confident, organellar_confident, ambiguous, unmapped
Percentages use total_pairs (trimmed pairs analysed) as denominator.
"""
import sys

run, total, org = sys.argv[1], int(sys.argv[2]), set(sys.argv[3].split(","))
counts = {"nuclear_confident": 0, "organellar_confident": 0, "ambiguous": 0, "unmapped": 0}
organelle_split = {c: 0 for c in sorted(org)}

def classify(recs):
    mapped = [(r[2], int(r[4])) for r in recs if not int(r[1]) & 0x4]
    if not mapped:
        return "unmapped", None
    conf = [(c, q) for c, q in mapped if q >= 20]
    if not conf:
        return "ambiguous", None
    if any(c not in org for c, _ in conf):
        return "nuclear_confident", None
    return "organellar_confident", conf[0][0]

cur, recs, seen = None, [], 0
def flush():
    global seen
    if recs:
        cls, oc = classify(recs); counts[cls] += 1; seen += 1
        if oc: organelle_split[oc] += 1

for line in sys.stdin:
    if line.startswith("@"): continue
    f = line.split("\t", 6)
    if f[0] != cur:
        flush(); cur, recs = f[0], []
    recs.append(f)
flush()

print("run\tclass\tfragments\tpct_of_trimmed_pairs")
for k, v in counts.items():
    print(f"{run}\t{k}\t{v}\t{100*v/total:.4f}")
for k, v in organelle_split.items():
    print(f"{run}\torganellar_confident:{k}\t{v}\t{100*v/total:.4f}")
print(f"{run}\tfragments_in_bam\t{seen}\t{100*seen/total:.4f}")
if seen != total:
    print(f"WARNING: fragments in BAM ({seen}) != trimmed pairs ({total})", file=sys.stderr)
