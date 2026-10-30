# cts_qiime

QIIME 2 (amplicon distribution, 2026.1) packaged for the KBase CDM Task Service (CTS).

- `entrypoint.sh pipeline <fastq.gz>...` runs the 454 single-end 16S pipeline
  (`pipeline.sh`): import → cutadapt primer trim → DADA2 `denoise-pyro` → SILVA
  classification → export. Settings are environment variables; see the header of
  `pipeline.sh`. Defaults target the 926F/1392R primers.
- Any other arguments are passed straight to `qiime`.
- All scratch/config writes go to `$TMPDIR`; outputs go to `$OUT_DIR` (default `/out`):
  - `qiime/*.qza`: QIIME artifacts
  - `export/feature-table.tsv` + `.biom`, `export/dna-sequences.fasta`,
    `export/taxonomy.tsv`, `export/denoising-stats.tsv`
  - `manifest.tsv`: sample ID → input file

## Parameters

Set parameters in the CTS job's `params.environment`. Any QIIME parameter of the three
steps can be set as `<STEP>_<PARAM>`. STEP is `CUTADAPT` (`cutadapt trim-single`), `DADA2`
(`dada2 denoise-pyro`) or `CLASSIFY` (`feature-classifier classify-sklearn`). PARAM is the
`--p-` name in upper case with `-` → `_`:

```json
"environment": {
  "DADA2_TRUNC_LEN": "400",
  "DADA2_POOLING_METHOD": "pseudo",
  "DADA2_ALLOW_ONE_OFF": "true",
  "CUTADAPT_FRONT": "AAACTYAAAKGAATTGRCGG,GTGCCAGCMGCCGCGGTAA",
  "CLASSIFY_CONFIDENCE": "0.8"
}
```

- Parameters you don't set aren't passed, so **QIIME's defaults apply**. See
  `qiime <step> --help` for the full lists.
- `true`/`false` become `--p-x`/`--p-no-x`, and commas separate multiple values. CTS values
  can't contain spaces.
- Misspelled names fail with QIIME's "No such option … Did you mean" error. The options each
  step used are logged, and the `.qza` provenance records them.

The pipeline sets defaults only where QIIME has none:
- `CUTADAPT_FRONT`: 926F, `AAACTYAAAKGAATTGRCGG`
- `CUTADAPT_ADAPTER`: 1392R reverse complement, `GYACACACCGCCCGT`
- `DADA2_TRUNC_LEN`: 400. Reads shorter than this are dropped; 0 turns truncation and
  length filtering off.

Pipeline settings: `THREADS` (default all CPUs; it sets cutadapt `cores`, DADA2 `n_threads`
and classifier `n_jobs` unless the step sets its own), `SKIP_TAXONOMY`, `CLASSIFIER`. Older
shorthands still work: `TRUNC_LEN`, `TRIM_LEFT`, `MAX_EE`, `FWD_PRIMER`, `REV_PRIMER_RC`,
`DISCARD_UNTRIMMED`.

## Build

Pushes and PRs build the image and run the pipeline on `test/data` (3 × 2000-read 454
samples, taxonomy skipped). Pushing a git tag also publishes
`ghcr.io/crockettz/cts_qiime:<tag>`.

## Reference data

The refdata is one archive of QIIME's pre-trained Naive Bayes classifiers for
scikit-learn 1.4.2, the version QIIME 2026.1 uses. Build it with
`refdata/build_classifier_bundle.sh`, then register the resulting
`cts_qiime_classifiers_sklearn-1.4.2.tar.gz` with the CTS **with unpack**. The files land
at the top level of the mount, so a job picks one with
`"CLASSIFIER": "/reference_data/<file>"`:

| File | Database | Weighting |
|---|---|---|
| `silva-138-99-nb-classifier.qza` (default) | SILVA 138 99%, full-length | uniform |
| `silva-138-99-nb-diverse-weighted-classifier.qza` | SILVA 138 99%, full-length | diverse environments |
| `2024.09.backbone.full-length.nb.sklearn-1.4.2.qza` | Greengenes2 2024.09 backbone, full-length | uniform |
| `gtdb_classifier_r220.qza` | GTDB r220 | uniform |
| `gtdb_diverse_weighted_classifier_r220.qza` | GTDB r220 | diverse environments |

**Size the job for the classifier.** QIIME unpacks the classifier into `$TMPDIR` and
loads it into memory, so jobs need far more than the download size. Measured with
`THREADS=1` on the 3-sample test data:

| Classifier | Unpacked size | Peak memory |
|---|---|---|
| SILVA 99% (default) | 1.4 GB | 4.9 GB |
| Greengenes2 full-length | 3.7 GB | 6.7 GB |
| GTDB r220 diverse-weighted | 5.6 GB | 9.5 GB |
| GTDB r220 | 8.1 GB | over 11 GB (not measured past that) |
| SILVA 99% diverse-weighted | 9.7 GB | over 11 GB (not measured past that) |

Allow temp disk of about twice the unpacked size. With more classifier jobs
(`THREADS` or `CLASSIFY_N_JOBS` > 1), memory may grow, so keep `CLASSIFY_N_JOBS=1` for the
two largest unless the job requests plenty of memory.

`/reference_data/CLASSIFIERS.tsv` in the bundle lists each file's source URL and SHA-256.
The V4 (515F–806R) and human-stool classifiers are left out because they don't suit V6–V8
environmental data. Classifiers only work with the scikit-learn version they were trained
with, so moving to a newer QIIME needs a new bundle, a new refdata registration and a new
image tag.

## Example CTS job

DADA2 must see every sample of a sequencing run together, so use one container.

```json
{
  "cluster": "perlmutter-jaws",
  "image": "ghcr.io/crockettz/cts_qiime@sha256:<digest>",
  "params": {
    "input_mount_point": "/in",
    "output_mount_point": "/out",
    "refdata_mount_point": "/reference_data",
    "args": ["pipeline", {"type": "input_files", "input_files_format": "space_separated_list"}],
    "environment": {"THREADS": "8", "TRUNC_LEN": "400"}
  },
  "input_files": ["<bucket>/pwdna/fastq/SRR573806.fastq.gz", "..."],
  "output_dir": "<bucket>/cts-output/qiime_test",
  "runtime": "PT2H",
  "cpus": 8,
  "num_containers": 1,
  "memory": "64GB"
}
```
