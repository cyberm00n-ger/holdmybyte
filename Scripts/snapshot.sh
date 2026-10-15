#!/usr/bin/env bash
# Renders the snapshot catalogue (Docs/SPEC.md §5.5, §6.3) with hmb-snapshot and prints the contact sheet path.
# Usage: Scripts/snapshot.sh [--release] [--self-test] [id,id,…]
# Uses HMB_FIXTURE_PHOTOS from ~/Library/Application Support/holdmybyte-dev/env.sh when it exists (outputs stay local;
# Snapshots/ is git-ignored). Every HMB_SNAPSHOT_* variable is passed through.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
CONFIG=debug
SELF_TEST=0
for arg in "$@"; do
    case "$arg" in
        --release) CONFIG=release ;;
        --self-test) SELF_TEST=1 ;;
        -*) echo "snapshot: unknown option $arg" >&2; exit 64 ;;
        *) export HMB_SNAPSHOT="$arg" ;;
    esac
done
ENV_FILE="$HOME/Library/Application Support/holdmybyte-dev/env.sh"
if [ -z "${HMB_FIXTURE_PHOTOS:-}" ] && [ -f "$ENV_FILE" ]; then
    # shellcheck source=/dev/null
    source "$ENV_FILE"
fi
swift build -c "$CONFIG" --product hmb-snapshot
BIN="$(swift build -c "$CONFIG" --show-bin-path)/hmb-snapshot"
export HMB_SNAPSHOT_DIR="${HMB_SNAPSHOT_DIR:-$ROOT/Snapshots}"
echo "snapshot: load before: $(uptime | sed 's/.*load averages*: //')"
start=$(date +%s)
set +e
if [ "$SELF_TEST" -eq 1 ]; then
    "$BIN" --self-test "$HMB_SNAPSHOT_DIR/self-test"
else
    "$BIN"
fi
status=$?
set -e
echo "snapshot: $(( $(date +%s) - start )) s, exit $status; load after: $(uptime | sed 's/.*load averages*: //')"
exit "$status"
