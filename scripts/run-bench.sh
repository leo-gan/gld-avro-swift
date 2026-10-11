#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
if [[ -d "${HOME}/.local/share/swiftly/bin" ]]; then
  export PATH="${HOME}/.local/share/swiftly/bin:${PATH}"
fi
swift run -c release avro-bench
