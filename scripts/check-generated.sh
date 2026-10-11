#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
if [[ -d "${HOME}/.local/share/swiftly/bin" ]]; then
  export PATH="${HOME}/.local/share/swiftly/bin:${PATH}"
fi
swift build --product gld-avrogen-swift
bin=".build/debug/gld-avrogen-swift"
out="$(mktemp -d)"
trap 'rm -rf "$out"' EXIT
"$bin" --schema testdata/avsc/kitchen.avsc --out "$out"
"$bin" --schema testdata/avsc/longlist.avsc --out "$out"
"$bin" --schema testdata/avsc/node.avsc --out "$out"
"$bin" --schema testdata/avsc/mutual.avsc --out "$out"
diff -ru tests/generated "$out"
