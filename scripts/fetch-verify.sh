#!/usr/bin/env bash
# Fetch the current official GoPro firmware for the requested model ids and
# run the SC-hook scanner on each DATA.bin.
#
# Usage:
#   ./scripts/fetch-verify.sh                 # HERO8..MAX2 (50 51 55 57 58 60 62 64 65)
#   ./scripts/fetch-verify.sh 65 62           # selected model ids
#
# Model ids are GoPro's catalog ids (58 = HERO11 Black, 65 = HERO13 Black, ...).
# The catalog endpoint is public and needs no authentication.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK="${WORK:-$ROOT/work/firmware}"
RESULTS="${RESULTS:-$ROOT/work/results}"
CATALOG="${CATALOG:-$ROOT/work/catalog.json}"
PY="${PY:-python3}"
MODELS=("$@")
if [ ${#MODELS[@]} -eq 0 ]; then
    MODELS=(50 51 55 57 58 60 62 64 65)
fi

mkdir -p "$WORK" "$RESULTS"
if [ ! -s "$CATALOG" ]; then
    echo "== fetching firmware catalog"
    curl -sS https://api.gopro.com/firmware/v2/catalog -o "$CATALOG"
fi

for id in "${MODELS[@]}"; do
    meta="$(python3 - "$CATALOG" "$id" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
c = next((x for x in d["cameras"] if str(x["model"]) == sys.argv[2]), None)
if c is None:
    sys.exit(3)
print("\t".join([c["name"], c["version"], c["sha1"], c["url"]]))
PY
)"
    IFS=$'\t' read -r name ver sha url <<< "$meta"
    dir="$WORK/$id"
    mkdir -p "$dir"

    if [ ! -f "$dir/DATA.bin" ]; then
        echo "== $name $ver: downloading"
        curl -sS -L --retry 3 --retry-all-errors -C - -o "$dir/UPDATE.zip" "$url"
        echo "$sha  $dir/UPDATE.zip" | sha1sum -c -
        unzip -o -q "$dir/UPDATE.zip" -d "$dir"
        rm -f "$dir/UPDATE.zip"
    fi

    if [ ! -f "$dir/DATA.bin" ]; then
        echo "== $name $ver: no DATA.bin (different container; not scanned)"
        continue
    fi

    "$PY" "$ROOT/scripts/fw-scan.py" "$dir/DATA.bin" \
        --model "$name" --version "$ver" \
        --json "$RESULTS/$id.json" >/dev/null
    python3 - "$RESULTS/$id.json" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
print(f"   {d.get('model')} {d.get('version')}: {d.get('verdict')}")
PY
done
