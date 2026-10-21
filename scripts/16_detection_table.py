#!/usr/bin/env python3
"""Step 16 — Build the quantitative detection table from result files (no hand-typed numbers).

Inputs: config/detection_candidates.tsv + results/ (steps 2, 6, 7, 9, 11, 12, 13, 14, 15) + metadata/stat_*.json
Outputs: results/detection_table.tsv and results/detection_table.md

Counting unit: fragment = read pair, counted once (never per mate).
Denominators:
  pct_of_analyzed = fragments / trimmed read pairs analysed (results/01_qc/retention.tsv)
  pct_of_nonhost  = fragments lying in the non-host pool / non-host pool pairs (step 11: pairs with both
                    mates unmapped to the A. hypogaea assembly + organelles)
near_identical_fragments:
  cellular candidates: Stage-A fragments with identity >= 0.98 and >= 80% of the read aligned
                       (source 'main': whole group; source 'nonhost': the named reference/label)
  viruses:             all-read remap fragments with MAPQ >= 20 on the assembled contig (the virus may
                       legitimately diverge from every database reference)
  human:               MAPQ >= 20 and identity >= 0.98 on GRCh38
detection_confidence (a rule on the evidence, NOT a significance judgement):
  not supported  near_identical < 10
  high           >= 2 screens agree AND near_identical >= 1,000 AND (viral breadth >= 90% at >= 10x
                 OR >= 100 distinct genes with >= 5 fragments OR human-confident on >= 10 sequences)
  moderate       >= 2 screens agree AND near_identical >= 100
  low            otherwise
'Screens' = STAT (>= 10 reads), Kraken2/Bracken in the non-host pool (>= 10 pairs), SendSketch hit.
significance_bin and likely_source are deliberately left for the student.
"""
import csv, glob, gzip, json, os, sys
from collections import defaultdict

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__))); os.chdir(ROOT)
R = "results"

def tsv(path):
    if not os.path.exists(path): return []
    with open(path) as fh:
        return list(csv.DictReader((l for l in fh if not l.startswith("#")), delimiter="\t"))

def num(x, d=None):
    try: return float(x)
    except (TypeError, ValueError): return d

trimmed = {r["run"]: int(r["pairs_after"]) for r in tsv(f"{R}/01_qc/retention.tsv")}
pool = {}
for p in glob.glob(f"{R}/02_host/genome/*/*.host_partition.tsv"):
    for r in csv.reader(open(p), delimiter="\t"):
        if len(r) > 2 and r[1] == "nonhost_pool_fastq_pairs": pool[r[0]] = int(r[2])

manifest = {}
for d in ("validation", "validation_nonhost"):
    for r in tsv(f"references/{d}/manifest.tsv"): manifest[r["label"]] = r["accession"]
for f in ("config/validation_panel.tsv", "config/validation_panel_nonhost.tsv"):   # fallback if references/ absent
    for line in open(f):
        if line.startswith("#") or not line.strip(): continue
        g, acc, typ, lab, role = line.rstrip("\n").split("\t")[:5]; manifest.setdefault(lab, acc)

def stat_count(run, names):
    f = f"metadata/stat_{run}.json"
    if names in ("", "-") or not os.path.exists(f): return None
    tab = json.load(open(f))[0]["tax_table"]
    return int(sum(next((t["total_count"] for t in tab if t["org"] == n), 0) for n in names.split(";")))

def kraken_count(run, names):
    if names in ("", "-"): return None
    tot = 0
    for lvl in ("S", "G"):
        for r in tsv(f"{R}/03_screen/kraken2/{run}/{run}.bracken_{lvl}.tsv"):
            if r["name"] in names.split(";"): tot += int(r["new_est_reads"])
    return tot

def sendsketch_best(run, names):
    if names in ("", "-"): return None
    best = None
    for db in ("nt", "refseq"):
        f = f"{R}/03_screen/sendsketch/{run}.{db}.tsv"
        if not os.path.exists(f): continue
        for line in open(f):
            r = line.rstrip("\n").split("\t")
            if line.startswith("#") or len(r) < 11: continue
            if any(r[1].startswith(n) for n in names.split(";")):
                w = num(r[10], 0)
                if best is None or w > best[1]: best = (num(r[2], 0), w, db)
    return best

_frag_cache = {}
def near_identical(tag, key, by):
    """count fragments with identity>=0.98 & aligned>=0.8, keyed by group or label"""
    if tag not in _frag_cache:
        f = f"{R}/04_validation/{tag}/{tag}.fragments.tsv.gz"
        cnt = {"group": defaultdict(int), "label": defaultdict(int)}
        if os.path.exists(f):
            with gzip.open(f, "rt") as fh:
                next(fh)
                for line in fh:
                    q, lab, grp, mq, ident, af, _ = line.rstrip("\n").split("\t")
                    if float(ident) >= 0.98 and float(af) >= 0.8:
                        cnt["group"][grp] += 1; cnt["label"][lab] += 1
        _frag_cache[tag] = cnt
    return _frag_cache[tag][by].get(key, 0)

def virus_contig_info(run, group):
    contig = {"potyvirus": "SRR29854842_k141_4", "polerovirus": "SRR29854842_k141_5"}.get(group)
    d = f"{R}/05_virus/{run}"
    if not contig or not os.path.exists(f"{d}/blastn_panel.tsv"): return None, ""
    bl = [r for r in csv.reader(open(f"{d}/blastn_panel.tsv"), delimiter="\t") if r[0] == contig]
    rm = {(r[0], r[1]): int(r[2]) for r in csv.reader(open(f"{d}/remap_fragments_per_contig.tsv"), delimiter="\t")}
    lens = dict(csv.reader(open(f"{d}/contig_lengths.tsv"), delimiter="\t"))
    b = max(bl, key=lambda r: float(r[11]))
    note = (f"MEGAHIT contig {contig} ({lens.get(contig, '?')} nt): BLASTn {float(b[2]):.2f}% id to {b[1]} over {b[3]} nt; "
            f"all-read remap {rm.get((contig, '0'), 0):,} fragments (MAPQ≥20 {rm.get((contig, '20'), 0):,}). ")
    pp = tsv(f"{d}/polerovirus_orfs/per_protein_identity.tsv")
    if group == "polerovirus" and pp:
        cp = [r for r in pp if r["reference"] == "NC_034247.1" and r["pident"] != "NA"]
        note += "aa id vs CPPV2: " + ", ".join(f"{r['protein'].replace(' protein', '')} {float(r['pident']):.1f}%" for r in cp) + ". "
    return rm.get((contig, "20"), 0), note

rows = []
for c in tsv("config/detection_candidates.tsv"):
    run, src, group, label = c["dataset"], c["source"], c["group"], c["label"]
    T, P = trimmed.get(run), pool.get(run)
    o = {k: "NA" for k in ["reference", "supporting_fragments", "near_identical_fragments", "fragments_mapq20",
                           "pct_of_analyzed", "pct_of_nonhost", "mean_depth", "breadth_1x_pct", "breadth_10x_pct",
                           "mean_identity", "gene_support", "STAT_reads", "Kraken2_Bracken_pairs_nonhost", "SendSketch_best"]}
    o = {"dataset": run, "candidate": c["candidate"], "evidence_source": src, **o}
    notes, screens, ni, extra_ok = "", 0, None, False
    s, k, ss = stat_count(run, c["names_stat"]), kraken_count(run, c["names_kraken"]), sendsketch_best(run, c["names_sendsketch"])
    if s is not None: o["STAT_reads"] = s; screens += s >= 10
    if k is not None: o["Kraken2_Bracken_pairs_nonhost"] = k; screens += k >= 10
    if ss is not None: o["SendSketch_best"] = f"ANI {ss[0]:.1f}%, WKID {ss[1]:.2f}% ({ss[2]})"; screens += 1
    elif c["names_sendsketch"] not in ("", "-"): o["SendSketch_best"] = "not detected"
    pct = lambda n, d, p=4: f"{100*n/d:.{p}f}" if d else "NA"

    if src in ("main", "nonhost"):
        tag = run if src == "main" else f"{run}.nonhost_nonhost"
        gs = {r["group"]: r for r in tsv(f"{R}/04_validation/{tag}/{tag}.group_summary.tsv")}
        ls_ = {r["label"]: r for r in tsv(f"{R}/04_validation/{tag}/{tag}.assignment_summary.tsv")}
        cov = {r["group"]: r for r in tsv(f"{R}/04_validation/{tag}/{tag}.coverage.tsv")}
        unit = gs.get(group) if src == "main" else ls_.get(label)
        n = int(unit["fragments"]) if unit else 0
        o.update(supporting_fragments=n, fragments_mapq20=unit["fragments_mapq20"] if unit else 0,
                 mean_identity=unit["mean_identity"] if unit else "NA", pct_of_analyzed=pct(n, T))
        if src == "main":
            ip = {r["group"]: r for r in tsv(f"{R}/04_validation/{run}/{run}.groups_in_nonhost_pool.tsv")}
            if group in ip and P: o["pct_of_nonhost"] = pct(int(ip[group]["in_nonhost_pool"]), P, 3)
            ni = near_identical(tag, group, "group")
        else:
            o["pct_of_nonhost"] = pct(n, P, 3); ni = near_identical(tag, label, "label")
            notes += f"Label-level counts within panel group '{group}'. "
        v = cov.get(group)
        if v and (src == "main" or v["label"] == label):
            o.update(mean_depth=v["meandepth"], breadth_1x_pct=v["breadth_1x_pct"], breadth_10x_pct=v["breadth_10x_pct"],
                     reference=f"{manifest.get(v['label'], 'NA')} ({v['label']})")
            extra_ok = "virus" in group and num(v["breadth_10x_pct"], 0) >= 90
        else:
            o["reference"] = f"{manifest.get(label, 'NA')} ({label})"
            if v: notes += f"Coverage columns omitted: group's Stage-B reference was {v['label']}. "
        if "virus" in group:
            q20, vnote = virus_contig_info(run, group); notes += vnote
            if q20 is not None: ni = q20
        gsum = tsv(f"{R}/04_validation/{run}/genes/{label}/gene_summary.tsv")
        if gsum:
            o["gene_support"] = (f"[vs {label}] " if v and v["label"] != label else "") + "; ".join(
                f"{r['stratum']}: {r['genes_ge1']} genes (≥5 frags: {r['genes_ge5']}), rRNA {r['pct_fragments_rRNA']}%" for r in gsum)
            extra_ok = extra_ok or any(int(r["genes_ge5"]) >= 100 for r in gsum)

    elif src == "human":
        hs = {r["metric"]: r for r in tsv(f"{R}/04_validation/human/{run}/{run}.human_summary.tsv")}
        if hs:
            ni = int(hs["human_confident_mapq20_id98"]["fragments"])
            o.update(reference="GRCh38 (GRCh38_full_as)", supporting_fragments=hs["aligned"]["fragments"],
                     fragments_mapq20=hs["mapq20"]["fragments"], pct_of_analyzed=pct(ni, T), pct_of_nonhost=pct(ni, P, 3))
            nseq = int(hs["confident_distinct_nuclear_sequences"]["fragments"])
            notes += (f"Human-confident pairs (MAPQ≥20, id≥0.98): {ni:,}; on chrM: {hs['confident_on_chrM']['fragments']}; "
                      f"distinct nuclear sequences: {nseq}. pct columns use human-confident pairs. ")
            extra_ok = nseq >= 10

    elif src == "kmer":
        rows_k = {}
        for st in ("domain_only", "bacteria_clade"):
            for r in tsv(f"{R}/03_screen/kraken2_all/{run}/{run}.{st}.by_host_class.tsv"): rows_k[(st, r["host_class"])] = int(r["fragments"])
        if rows_k:
            tot_d, tot_c = rows_k.get(("domain_only", "TOTAL_in_set"), 0), rows_k.get(("bacteria_clade", "TOTAL_in_set"), 0)
            un_d, un_c = rows_k.get(("domain_only", "unmapped"), 0), rows_k.get(("bacteria_clade", "unmapped"), 0)
            o.update(reference="A. hypogaea GCF_003086295.3 + MW448460.1 (host)", supporting_fragments=tot_c,
                     pct_of_analyzed=pct(tot_c, T))
            notes += (f"Kraken2 (all {T:,} trimmed pairs): Bacteria clade {tot_c:,} pairs, of which {tot_c-un_c:,} "
                      f"({100*(tot_c-un_c)/tot_c:.2f}%) align to the peanut assembly and {un_c:,} are unmapped; domain-only "
                      f"{tot_d:,} pairs, {100*(tot_d-un_d)/tot_d:.2f}% host-aligned. ")
        org = {r["metric"]: r for r in tsv(f"{R}/02_host/organelles/{run}.organelle_counts.tsv")}
        if org: notes += f"Organelle-only mapping: {int(org['organelle_any']['fragments']):,} pairs ({org['organelle_any']['pct_of_trimmed_pairs']}%) organelle-like. "
        o["detection_confidence"] = "host-derived (see notes)"

    elif src == "chimera":
        f = "logs/asc/a1_chimera_test.txt"
        if os.path.exists(f):
            txt = open(f).read().splitlines()
            sp = [l for l in txt if "spanning_reads_e2e" in l]
            rr = [l for l in txt if l.startswith("host_18S/28S_rRNA")]
            notes += ("BCMV reads with mate on host 18S/28S rRNA: " + (rr[0].split("\t")[1] if rr else "?") +
                      " pairs; end-to-end junction-spanning reads per contig: " +
                      ", ".join(l.split("\t")[0].split("_")[-1] + "=" + l.split("=")[1].split("\t")[0] for l in sp) + ". ")
        o["detection_confidence"] = "artifact (see notes)"

    if ni is not None: o["near_identical_fragments"] = ni
    if "detection_confidence" not in o:
        if ni is not None and ni < 10: o["detection_confidence"] = "not supported"
        elif screens >= 2 and ni and ni >= 1000 and extra_ok: o["detection_confidence"] = "high"
        elif screens >= 2 and ni and ni >= 100: o["detection_confidence"] = "moderate"
        else: o["detection_confidence"] = "low"
    o["independent_screens_agreeing"] = screens
    o["validation_notes"] = notes.strip() or "-"
    o["competing_explanations"] = c["competing_explanations"]; o["limitations"] = c["limitations"]
    o["significance_bin"] = "(student decision)"; o["likely_source"] = "(student decision)"
    rows.append(o)

cols = list(rows[0].keys())
with open(f"{R}/detection_table.tsv", "w") as fo:
    fo.write("\t".join(cols) + "\n")
    for r in rows: fo.write("\t".join(str(r[c]) for c in cols) + "\n")
with open(f"{R}/detection_table.md", "w") as fo:
    fo.write("# Detection table\n\nGenerated by `scripts/16_detection_table.py` from result files. Denominators and the "
             "confidence rule are defined in the script header and `docs/METHODS.md`. Fragments = read pairs. "
             "Significance bin and likely source are for the student to decide.\n\n")
    fo.write("| " + " | ".join(cols) + " |\n|" + "---|" * len(cols) + "\n")
    for r in rows: fo.write("| " + " | ".join(str(r[c]).replace("|", "/") for c in cols) + " |\n")
print(f"{len(rows)} rows -> {R}/detection_table.tsv", file=sys.stderr)
