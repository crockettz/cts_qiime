# cts_qiime2

QIIME 2 (amplicon distribution) packaged for the KBase CDM Task Service (CTS).

- Entrypoint runs `qiime <args>`; all scratch/config writes go to `$TMPDIR`.
- Write all outputs under the CTS output mount (e.g. `/out`).
- Build: push a git tag → GitHub Actions publishes `ghcr.io/<owner>/cts_qiime2:<tag>`.
  Make the package **public** in GitHub so the CTS can pull it.
