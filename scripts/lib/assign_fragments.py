#!/usr/bin/env python3
"""Assign each read pair (fragment) to the panel label/group of its best primary alignment.

stdin : SAM records (primary, mapped only: samtools view -F 0x904)
args  : contig_map.tsv  total_pairs  out_fragments.tsv.gz  out_label_summary.tsv  out_group_summary.tsv

Per fragment the mate with the higher alignment score (AS) is used; ties -> R1.
identity     = (aligned columns - NM) / aligned columns, aligned columns = M/=/X + I + D
aligned_frac = aligned query bases / read length (local mode soft-clips divergent ends)
Denominators:
  pct_trimmed         fragments / trimmed pairs analysed (all input pairs)
  pct_candidate_hits  fragments / fragments assigned to any non-decoy panel group
                      (NOT the true non-host pool: the nuclear host genome is not in the panel)
"""
import csv, gzip, re, statistics, sys
from collections import defaultdict

cmap_f, total, out_frag, out_label, out_group = sys.argv[1], int(sys.argv[2]), *sys.argv[3:6]
contig = {}
for r in csv.DictReader(open(cmap_f), delimiter="\t"):
    contig[r["contig"]] = (r["label"], r["group"])

CIG = re.compile(r"(\d+)([MIDNSHP=X])")
best = {}  # qname -> (AS, label, group, mapq, identity, aligned_frac, mate)
for line in sys.stdin:
    f = line.rstrip("\n").split("\t")
    qname, flag, rname, mapq, cigar, seq = f[0], int(f[1]), f[2], int(f[4]), f[5], f[9]
    tags = {t[:2]: t[5:] for t in f[11:]}
    AS, NM = int(tags.get("AS", 0)), int(tags.get("NM", 0))
    cols = qbases = 0
    for n, op in CIG.findall(cigar):
        n = int(n)
        if op in "M=X": cols += n; qbases += n
        elif op == "I": cols += n; qbases += n
        elif op == "D": cols += n
    ident = (cols - NM) / cols if cols else 0.0
    afrac = qbases / len(seq) if seq != "*" and len(seq) else 0.0
    mate = 1 if flag & 0x40 else 2
    label, group = contig.get(rname, (rname, "unknown"))
    cur = best.get(qname)
    if cur is None or AS > cur[0] or (AS == cur[0] and mate == 1 and cur[6] == 2):
        best[qname] = (AS, label, group, mapq, ident, afrac, mate)

lab = defaultdict(lambda: {"n": 0, "q20": 0, "id": [], "full": 0, "group": ""})
grp = defaultdict(lambda: {"n": 0, "q20": 0, "id": [], "full": 0, "labels": defaultdict(int)})
with gzip.open(out_frag, "wt") as fo:
    fo.write("fragment\tlabel\tgroup\tmapq\tidentity\taligned_frac\tmate_used\n")
    for q, (AS, label, group, mapq, ident, afrac, mate) in best.items():
        fo.write(f"{q}\t{label}\t{group}\t{mapq}\t{ident:.4f}\t{afrac:.3f}\t{mate}\n")
        for d in (lab[label], grp[group]):
            d["n"] += 1; d["q20"] += mapq >= 20; d["id"].append(ident); d["full"] += afrac >= 0.8
        lab[label]["group"] = group
        grp[group]["labels"][label] += 1

cand_total = sum(v["n"] for g, v in grp.items() if g != "host_decoy")
def pct(a, b): return f"{100*a/b:.5f}" if b else "NA"
def row(name, d):
    ids = d["id"]
    return [d["n"], d["q20"], pct(d["n"], total), pct(d["n"], cand_total),
            f"{statistics.mean(ids):.4f}" if ids else "NA", f"{statistics.median(ids):.4f}" if ids else "NA",
            pct(d["full"], d["n"])]
hdr = ["fragments", "fragments_mapq20", "pct_trimmed", "pct_candidate_hits",
       "mean_identity", "median_identity", "pct_aligned_ge80"]
with open(out_label, "w") as fo:
    fo.write("\t".join(["group", "label"] + hdr) + "\n")
    for l, d in sorted(lab.items(), key=lambda kv: (kv[1]["group"], -kv[1]["n"])):
        fo.write("\t".join(map(str, [d["group"], l] + row(l, d))) + "\n")
with open(out_group, "w") as fo:
    fo.write("\t".join(["group"] + hdr + ["best_label", "best_label_fragments", "total_pairs", "candidate_hit_fragments"]) + "\n")
    for g, d in sorted(grp.items(), key=lambda kv: -kv[1]["n"]):
        bl = max(d["labels"].items(), key=lambda kv: kv[1])
        fo.write("\t".join(map(str, [g] + row(g, d) + [bl[0], bl[1], total, cand_total])) + "\n")
print(open(out_group).read(), file=sys.stderr)
