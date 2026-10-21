# A divergent polerovirus related to cowpea polerovirus 2 in a peanut root-nodule transcriptome

## Observation
The *Arachis hypogaea* root-nodule RNA-seq run **SRR29854842** (Fuzhou, China; 21,444,624 read pairs after trimming) contains a near-complete polerovirus genome. Three independent screens flagged it:
- NCBI STAT: 2,164 reads as "Polerovirus CPPV2";
- Kraken2/Bracken on the non-host pool: 2,557 pairs;
- competitive mapping against a panel of five poleroviruses plus a host decoy: 3,869 read pairs, 98% of them aligned over ≥ 80% of the read, almost all assigned to CPPV2 (NC_034247.1).

The supporting pairs are 0.018% of analysed pairs and 0.38% of the 1,008,951-pair non-host pool. 99.9% of them do not align to the peanut genome.

## Validation
- **Assembly:** MEGAHIT, run on the recruited reads, produced a single **5,851-nt contig** (`SRR29854842_k141_5`), close to the 5,945-nt CPPV2 genome.
- **Read support across the contig:** all 21.4 M trimmed pairs were remapped to it. 4,254 pairs aligned (4,233 at MAPQ ≥ 20), covering **100% of the contig at a mean depth of 211×**. Coverage is even, unlike the strongly 3′-biased co-infecting BCMV (`results/figures/fig2_virus_coverage.png`).
- **Genome organisation:** an HMMER search found a complete RdRp_4 domain (Pfam PF02123, E = 4×10⁻⁹¹), the polymerase family of poleroviruses.
- **Similarity to known viruses:** the contig is **92.4% identical at the nucleotide level** to the only complete CPPV2 genome (isolate BE179, from cowpea, *Vigna unguiculata*, collected 2013; Arch. Virol. 2017, PMID 28337544) across 97% of its length. Every other polerovirus tested is much more distant (P1-P2 ≤ 85.8%).
- **Per-protein amino-acid identity to CPPV2 BE179 (tblastn):**

| Protein | Identity | Difference |
|---|---|---|
| P0 | 83.5% | 16.5% |
| P1 | 89.9% | 10.1% |
| Movement protein | 91.5% | 8.5% |
| Read-through protein | 92.7% | 7.3% |
| P3a | 93.5% | 6.5% |
| P2 (RdRp) | 96.3% | 3.7% |
| Coat protein | 98.5% | 1.5% |

## Interpretation
1. **A divergent CPPV2 isolate infecting peanut.** The coat protein (98.5%) and RdRp (96.3%) are very close to CPPV2, and P0, the suppressor of RNA silencing, is typically the most variable polerovirus protein. Poleroviruses are aphid-transmitted and phloem-limited, and a nodule sample can carry phloem sap. That would be a biological finding worth reporting, not a contamination artefact.
- **Limitations:**
  - Only one complete CPPV2 reference exists.
  - The contig hasn't been confirmed by RT-PCR or Sanger sequencing.
  - This is a single sample, with no sibling-run comparison yet.
