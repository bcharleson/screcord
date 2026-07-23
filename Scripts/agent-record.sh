#!/usr/bin/env bash
# Agent-friendly wrapper: requires --duration, defaults countdown 0.
set -euo pipefail

DISPLAY_INDEX="${DISPLAY_INDEX:-0}"
AUDIO_MODE="${AUDIO_MODE:-system}"
DURATION="${DURATION:-}"
OUTPUT="${OUTPUT:-}"
EXTRA_ARGS=()

usage() {
  cat <<'EOF'
Usage: Scripts/agent-record.sh --duration <sec> [options]

Options:
  --duration <sec>   Required. Auto-stop after N seconds.
  --display <n>      Display index (default: 0)
  --audio <mode>     none|system|mic|both (default: system)
  --output <path>    Output .mp4 path
  --region x,y,w,h   Optional region
  --no-cursor        Hide cursor
  --fps <n>          Frame rate

Env vars: DISPLAY_INDEX, AUDIO_MODE, DURATION, OUTPUT
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --duration|-t) DURATION="$2"; shift 2 ;;
    --display|-d) DISPLAY_INDEX="$2"; shift 2 ;;
    --audio|-a) AUDIO_MODE="$2"; shift 2 ;;
    --output|-o) OUTPUT="$2"; shift 2 ;;
    --region|-r) EXTRA_ARGS+=(--region "$2"); shift 2 ;;
    --no-cursor) EXTRA_ARGS+=(--no-cursor); shift ;;
    --fps) EXTRA_ARGS+=(--fps "$2"); shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown option: $1" >&2; usage; exit 1 ;;
  esac
done

if [[ -z "$DURATION" ]]; then
  echo "error: --duration is required for agent recordings" >&2
  usage
  exit 1
fi

if command -v screcord >/dev/null 2>&1; then
  BIN="screcord"
elif [[ -x "$HOME/.local/bin/screcord" ]]; then
  BIN="$HOME/.local/bin/screcord"
elif [[ -x "$(dirname "$0")/../.build/release/screcord" ]]; then
  BIN="$(dirname "$0")/../.build/release/screcord"
else
  echo "error: screcord not found. Run: make build && PREFIX=\"\$HOME/.local\" make install" >&2
  exit 1
fi

ARGS=(record --display "$DISPLAY_INDEX" --audio "$AUDIO_MODE" --countdown 0 --duration "$DURATION")
if [[ -n "$OUTPUT" ]]; then
  ARGS+=(--output "$OUTPUT")
fi
ARGS+=("${EXTRA_ARGS[@]}")

echo "→ $BIN ${ARGS[*]}"
exec "$BIN" "${ARGS[@]}"
