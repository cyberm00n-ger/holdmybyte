#!/usr/bin/env bash
# Runs one §6.2 gate set with `hmb bench` (release build) into Benchmarks/runs/<timestamp>-<name>/.
# Usage: Scripts/bench.sh <name> [extra hmb bench arguments]
#   holdout          G1 + G2: holdout, Couple’s Package, repeat 2, A/B against $HMB_OLD_ENGINE
#   wedding-couple   G3 (+ G8 with --resume-check)
#   wedding-high     G4: custom High full-size
#   wedding-website  G5: Website alone
#   wedding-social   G5: Social & Blog
#   wedding-archive  G6: Archive alone
#   wedding-all      G7: all four deliveries in one run
# Reads HMB_HOLDOUT, HMB_WEDDING and HMB_OLD_ENGINE (source ~/Library/Application Support/holdmybyte-dev/env.sh).
# The machine should be quiet (1-minute load < 3, Lightroom closed); otherwise timing gates are not reported.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
die() { echo "bench: error: $*" >&2; exit 1; }
[ "$#" -ge 1 ] || die "usage: Scripts/bench.sh <holdout|wedding-couple|wedding-high|wedding-website|wedding-social|wedding-archive|wedding-all> [hmb bench args]"
NAME="$1"; shift
ENV_FILE="$HOME/Library/Application Support/holdmybyte-dev/env.sh"
if [ -f "$ENV_FILE" ]; then
    # shellcheck source=/dev/null
    source "$ENV_FILE"
fi

case "$NAME" in
    holdout)
        [ -n "${HMB_HOLDOUT:-}" ] || die "HMB_HOLDOUT is not set"
        SET="$HMB_HOLDOUT"; ARGS=(--delivery couple --repeat 2)
        if [ -n "${HMB_OLD_ENGINE:-}" ] && [ -x "$HMB_OLD_ENGINE" ]; then ARGS+=(--old-engine "$HMB_OLD_ENGINE"); fi ;;
    wedding-couple)  SET="${HMB_WEDDING:-}"; ARGS=(--delivery couple --repeat 2) ;;
    wedding-high)    SET="${HMB_WEDDING:-}"; ARGS=(--delivery high-full) ;;
    wedding-website) SET="${HMB_WEDDING:-}"; ARGS=(--delivery website --repeat 2) ;;
    wedding-social)  SET="${HMB_WEDDING:-}"; ARGS=(--delivery social) ;;
    wedding-archive) SET="${HMB_WEDDING:-}"; ARGS=(--delivery archive --repeat 2) ;;
    wedding-all)     SET="${HMB_WEDDING:-}"; ARGS=(--delivery couple --delivery website --delivery social --delivery archive --repeat 2) ;;
    *) die "unknown bench $NAME" ;;
esac
[ -n "$SET" ] && [ -d "$SET" ] || die "the set for $NAME is missing (HMB_WEDDING / HMB_HOLDOUT)"

OUT="$ROOT/Benchmarks/runs/$(date +%Y%m%d-%H%M%S)-$NAME"
swift build -c release --product hmb
HMB="$(swift build -c release --show-bin-path)/hmb"
echo "bench: load before: $(uptime | sed 's/.*load averages*: //')"
set +e
"$HMB" bench --set "$SET" --out "$OUT" --label "$NAME" --baselines "$ROOT/Benchmarks/baselines.json" "${ARGS[@]}" "$@"
status=$?
set -e
echo "bench: load after: $(uptime | sed 's/.*load averages*: //')"
echo "bench: $OUT (exit $status)"
exit "$status"
