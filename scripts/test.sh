#!/bin/bash
# Runs the CLI suite (pytest) and the Swift model checks (swiftc, no Xcode test host).
set -euo pipefail
cd "$(dirname "$0")/.."
PY="/opt/homebrew/bin/python3"
[ -x "$PY" ] || PY="python3"
"$PY" -m pytest -q tests/test_cli.py
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
cp tests/ModelTests.swift "$work/main.swift"   # top-level code is only allowed in main.swift
swiftc -o "$work/model-tests" RecurringApp/Sources/Model.swift "$work/main.swift"
# 20k random doubles across magnitudes, written by Python, re-printed by the app's writer
"$PY" -c 'import json,random,sys; r=random.Random(7); xs=[r.uniform(-1,1)*10**r.randint(-12,20) for _ in range(10000)]+[round(r.uniform(0,5000),2) for _ in range(10000)]; sys.stdout.write(json.dumps(xs,indent=2)+"\n")' > "$work/floats.json"
PARITY_DIR="$PWD/tests/fixtures" PYJSON_RANDOM="$work/floats.json" "$work/model-tests"
