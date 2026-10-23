#!/bin/bash
# CTS entrypoint: point every writable location at the temp dir (CTS only permits
# writes to the output mount and temp), then pass args straight to `qiime`.
set -euo pipefail

export TMPDIR="${TMPDIR:-/tmp}"
export HOME="$TMPDIR/home"
export XDG_CONFIG_HOME="$HOME/.config"
export XDG_CACHE_HOME="$HOME/.cache"
export MPLCONFIGDIR="$HOME/.matplotlib"
mkdir -p "$XDG_CONFIG_HOME" "$XDG_CACHE_HOME" "$MPLCONFIGDIR"

exec qiime "$@"
