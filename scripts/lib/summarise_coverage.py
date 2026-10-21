#!/usr/bin/env python3
"""Aggregate samtools coverage/depth for one reference label (possibly multi-contig) into one row.

args: group label coverage.tsv depth.tsv(-a) label.bam
Breadth = % of reference positions with depth >= 1 / 5 / 10. Mean depth is length-weighted.
Stage B fragments are counted once per pair (R1, or R2 if R1 unmapped); identity as in
assign_fragments.py (aligned columns - NM) / aligned columns, averaged over primary records.
"""
import csv, re, subprocess, sys

group, label, cov_f, depth_f, bam = sys.argv[1:6]
rows = list(csv.DictReader(open(cov_f), delimiter="\t"))
L = sum(int(r["endpos"]) - int(r["startpos"]) + 1 for r in rows)
nreads = sum(int(r["numreads"]) for r in rows)
covb = sum(int(r["covbases"]) for r in rows)
mdepth = sum(float(r["meandepth"]) * (int(r["endpos"]) - int(r["startpos"]) + 1) for r in rows) / L if L else 0
w = [(float(r["meanbaseq"]), float(r["meanmapq"]), int(r["numreads"])) for r in rows]
mbq = sum(a * n for a, _, n in w) / nreads if nreads else 0
mmq = sum(b * n for _, b, n in w) / nreads if nreads else 0

ge5 = ge10 = 0
with open(depth_f) as fh:
    for line in fh:
        d = int(line.rsplit("\t", 1)[1])
        ge5 += d >= 5; ge10 += d >= 10

CIG = re.compile(r"(\d+)([MIDNSHP=X])")
frags, ids = set(), []
p = subprocess.Popen(["samtools", "view", "-F", "0x904", bam], stdout=subprocess.PIPE, text=True)
for line in p.stdout:
    f = line.split("\t")
    flag = int(f[1])
    if flag & 0x40 or (flag & 0x80 and flag & 0x8):
        frags.add(f[0])
    nm = next((int(t[5:]) for t in f[11:] if t.startswith("NM:i:")), 0)
    cols = sum(int(n) for n, op in CIG.findall(f[5]) if op in "M=XID")
    if cols: ids.append((cols - nm) / cols)
if p.wait() != 0: sys.exit("samtools view failed on " + bam)

pct = lambda x: f"{100*x/L:.3f}" if L else "NA"
print("\t".join(map(str, [group, label, f"n_contigs={len(rows)}", L, nreads, covb, pct(covb),
      f"{mdepth:.3f}", f"{mbq:.1f}", f"{mmq:.1f}", pct(ge5), pct(ge10), len(frags),
      f"{sum(ids)/len(ids):.4f}" if ids else "NA"])))
