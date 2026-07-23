#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

echo "==> Building screcord (release)"
make build

PREFIX="${PREFIX:-/usr/local}"
echo "==> Installing to ${PREFIX}/bin/screcord"
make install PREFIX="$PREFIX"

echo ""
echo "Done. Next steps:"
echo "  1. Grant Screen Recording to your terminal app"
echo "     System Settings → Privacy & Security → Screen & System Audio Recording"
echo "  2. Grant Microphone access if you use --audio mic|both"
echo "  3. Run: screcord devices"
echo "  4. Run: screcord record"
