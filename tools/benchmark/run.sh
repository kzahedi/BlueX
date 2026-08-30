#!/bin/zsh
# Benchmark one model on the pinned set, then regenerate the report.
# Usage: tools/benchmark/run.sh <model-id>   (e.g. gemma4:12b)
set -u

if [ $# -lt 1 ]; then
  echo "usage: $0 <model-id>" >&2
  exit 2
fi
MODEL="$1"
HERE="${0:A:h}"
SET="${BLUEX_FIXTURES:-/Volumes/Eregion/bluex-data/test-fixtures/benchmark}/benchmark-set.json"
ANNOTATE="$HOME/.local/bin/blueX-annotate"

if [ ! -f "$SET" ]; then
  echo "benchmark set not found: $SET — run build_set.py first." >&2
  exit 1
fi

echo "warming $MODEL…"
curl -s -o /dev/null http://localhost:11434/api/generate \
  -d "{\"model\":\"$MODEL\",\"prompt\":\"warmup\",\"stream\":false}" 2>/dev/null

echo "annotating benchmark set with $MODEL…"
"$ANNOTATE" --benchmark "$SET" --pass llm --model "$MODEL" --pace steady

echo "generating report…"
python3 "$HERE/report.py" "${MODEL//[:\/]/-}"
