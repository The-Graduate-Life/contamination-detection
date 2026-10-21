#!/usr/bin/env python3
"""Step 17 — Figures (static PNG, light surface) drawn from result files.

fig1_host_partition.png : 100% stacked bars of host classes per run (step 11)
fig2_virus_coverage.png : per-base depth along the BCMV and polerovirus contigs (step 7 all-read remap),
                          two separate panels (no shared/dual axis), log10 depth
Palette: validated categorical slots 1-4 (blue, orange, aqua, yellow; validate_palette.js light: all
hard checks pass; aqua/yellow < 3:1 contrast -> every segment is direct-labelled in text ink and the
numbers are also in results/02_host/genome/*/host_partition.tsv).
"""
import csv, os
import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__))); os.chdir(ROOT)
OUT = "results/figures"; os.makedirs(OUT, exist_ok=True)
SURF, INK, INK2, GRID = "#fcfcfb", "#0b0b0b", "#52514e", "#e4e3df"
SERIES = ["#2a78d6", "#eb6834", "#1baf7a", "#eda100"]
plt.rcParams.update({"font.family": "DejaVu Sans", "font.size": 10, "axes.edgecolor": GRID,
                     "axes.labelcolor": INK2, "xtick.color": INK2, "ytick.color": INK2,
                     "figure.facecolor": SURF, "axes.facecolor": SURF, "savefig.facecolor": SURF})

# ---- Figure 1: host partition ----
runs = [("SRR39022911", "WGS (leaf)"), ("SRR29854842", "RNA-seq (nodule)")]
classes = [("nuclear_confident", "Nuclear, MAPQ≥20"), ("organellar_confident", "Organellar, MAPQ≥20"),
           ("ambiguous", "Host, ambiguous (MAPQ<20)"), ("unmapped", "Non-host pool (both mates unmapped)")]
vals = {}
for run, _ in runs:
    for r in csv.reader(open(f"results/02_host/genome/{run}/{run}.host_partition.tsv"), delimiter="\t"):
        if len(r) == 4 and r[1] in dict(classes): vals[(run, r[1])] = (int(r[2]), float(r[3]))
fig, ax = plt.subplots(figsize=(9, 2.9))
for i, (run, lab) in enumerate(runs):
    left = 0
    for j, (c, cl) in enumerate(classes):
        n, pct = vals[(run, c)]
        ax.barh(i, pct, left=left, height=0.55, color=SERIES[j], edgecolor=SURF, linewidth=2,
                label=cl if i == 0 else None)
        if pct >= 6:
            ax.text(left + pct / 2, i, f"{pct:.1f}%", ha="center", va="center", color=INK, fontsize=9)
        left += pct
    org, unm = vals[(run, "organellar_confident")][1], vals[(run, "unmapped")]
    ax.text(101, i, f"non-host {unm[1]:.2f}%\n({unm[0]:,} pairs)\norganellar {org:.3f}%", va="center",
            ha="left", fontsize=8.5, color=INK2)
ax.set_yticks(range(len(runs)), [f"{l}\n{r}" for r, l in runs], color=INK)
ax.set_xlim(0, 100); ax.set_xlabel("% of trimmed read pairs (one count per pair)")
ax.invert_yaxis()
for s in ("top", "right", "left"): ax.spines[s].set_visible(False)
ax.set_title("Host-read partition against A. hypogaea Tifrunner gnm2 + organelles", loc="left", color=INK, fontsize=11)
ax.legend(ncol=2, loc="upper center", bbox_to_anchor=(0.45, -0.32), frameon=False, fontsize=8.5, labelcolor=INK)
fig.tight_layout(); fig.savefig(f"{OUT}/fig1_host_partition.png", dpi=200, bbox_inches="tight"); plt.close(fig)

# ---- Figure 2: virus coverage ----
cov = {r["#rname"] if "#rname" in r else r["rname"]: r for r in csv.DictReader(open("results/05_virus/SRR29854842/remap_coverage.tsv"), delimiter="\t")}
panels = [("SRR29854842_k141_4", "Bean common mosaic virus contig (k141_4)"),
          ("SRR29854842_k141_5", "Polerovirus contig, CPPV2-related (k141_5)")]
fig, axes = plt.subplots(2, 1, figsize=(9, 5.2))
for ax, (contig, title) in zip(axes, panels):
    pos, dep = [], []
    for line in open(f"results/05_virus/SRR29854842/depth_{contig.split('_', 1)[1]}.tsv"):
        _, p, d = line.split("\t"); pos.append(int(p)); dep.append(max(int(d), 0.5))
    ax.plot(pos, dep, color=SERIES[0], linewidth=1.2)
    ax.fill_between(pos, 0.5, dep, color=SERIES[0], alpha=0.12, linewidth=0)
    ax.set_yscale("log"); ax.set_ylim(0.5, max(dep) * 2); ax.set_xlim(1, len(pos))
    c = cov[contig]
    ax.set_title(f"{title}: {len(pos):,} nt, breadth {float(c['coverage']):.1f}%, mean depth {float(c['meandepth']):,.0f}×",
                 loc="left", color=INK, fontsize=10)
    ax.grid(axis="y", color=GRID, linewidth=0.6); ax.set_axisbelow(True)
    for s in ("top", "right"): ax.spines[s].set_visible(False)
    ax.set_ylabel("depth (log10)")
axes[-1].set_xlabel("contig position (nt) — all trimmed pairs remapped (Bowtie2 end-to-end)")
fig.tight_layout(); fig.savefig(f"{OUT}/fig2_virus_coverage.png", dpi=200, bbox_inches="tight"); plt.close(fig)
print("figures ->", OUT)
