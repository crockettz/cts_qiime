#!/bin/bash
# CTS entrypoint: point every writable location at a per-run directory under the temp dir
# (CTS only permits writes to the output mount and temp, and temp may be shared between
# jobs), then run the pipeline (`pipeline <fastqs...>`) or pass args straight to `qiime`.
# The per-run directory is removed on exit.
set -euo pipefail

RUN_TMP="$(mktemp -d "${TMPDIR:-/tmp}/cts_qiime.XXXXXXXXXX")"
trap 'rm -rf "$RUN_TMP"' EXIT

export TMPDIR="$RUN_TMP"
export HOME="$TMPDIR/home"
export XDG_CONFIG_HOME="$HOME/.config"
export XDG_CACHE_HOME="$HOME/.cache"
export MPLCONFIGDIR="$HOME/.matplotlib"
mkdir -p "$XDG_CONFIG_HOME" "$XDG_CACHE_HOME" "$MPLCONFIGDIR"

# Not exec: the shell has to outlive the command so the EXIT trap can clean up.
if [[ "${1:-}" == "pipeline" ]]; then
    shift
    /opt/cts/pipeline.sh "$@"
else
    qiime "$@"
fi
