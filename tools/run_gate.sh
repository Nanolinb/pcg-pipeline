#!/usr/bin/env bash
set -u

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
GODOT_BIN="${GODOT_BIN:-}"

if [[ -z "$GODOT_BIN" ]]; then
	if command -v godot >/dev/null 2>&1; then
		GODOT_BIN="$(command -v godot)"
	elif command -v godot4 >/dev/null 2>&1; then
		GODOT_BIN="$(command -v godot4)"
	elif [[ -x /Applications/Godot.app/Contents/MacOS/Godot ]]; then
		GODOT_BIN=/Applications/Godot.app/Contents/MacOS/Godot
	else
		printf 'GATE_FAIL: Godot executable not found; set GODOT_BIN\n' >&2
		exit 1
	fi
fi
export GODOT_BIN

failures=0

run_test() {
	local name="$1"
	shift
	printf '\nGATE_BEGIN: %s\n' "$name"
	if "$@"; then
		printf 'GATE_PASS: %s\n' "$name"
	else
		local code=$?
		printf 'GATE_FAIL: %s (exit=%d)\n' "$name" "$code" >&2
		failures=$((failures + 1))
	fi
}

run_logged_test() {
	local name="$1"
	local marker="$2"
	shift 2
	printf '\nGATE_BEGIN: %s\n' "$name"
	local output
	local code=0
	output="$("$@" 2>&1)" || code=$?
	printf '%s\n' "$output"
	if [[ "$code" -eq 0 ]] && grep -q "$marker" <<<"$output"; then
		printf 'GATE_PASS: %s\n' "$name"
	else
		printf 'GATE_FAIL: %s (exit=%d, missing marker=%s)\n' "$name" "$code" "$marker" >&2
		failures=$((failures + 1))
	fi
}

run_versions() {
	python3 - "$ROOT_DIR" <<'PY'
from pathlib import Path
import re
import sys

root = Path(sys.argv[1])
versions = {}
for project in (root / "project.godot", root / "PipeWeaver" / "project.godot"):
    text = project.read_text()
    match = re.search(r'^config/version="([^"]+)"', text, re.M)
    if match is None:
        raise SystemExit(f"GATE_FAIL: missing config/version in {project}")
    versions[project] = match.group(1)
if len(set(versions.values())) != 1:
    raise SystemExit(f"GATE_FAIL: version mismatch: {versions}")
for project, version in versions.items():
    print(f"GATE_VERSION: {project} = {version}")
PY
}

run_test "project versions" run_versions
run_logged_test "Surface Component headless smoke" "PCG_SMOKE_TEST_PASS" "$GODOT_BIN" --headless --path "$ROOT_DIR" -s scripts/tests/run_smoke_test.gd
run_logged_test "PipeWeaver headless smoke" "PIPE_SMOKE_PASS" "$GODOT_BIN" --headless --path "$ROOT_DIR/PipeWeaver" res://tests/pipeweaver_smoke.tscn
run_test "shared addon cold-import spike" "$ROOT_DIR/tools/run_shared_addon_spike.sh"

if [[ "$failures" -ne 0 ]]; then
	printf '\nGATE_FAIL: %d test group(s) failed\n' "$failures" >&2
	exit 1
fi

printf '\nGATE_PASS: all headless checks passed\n'
printf 'GATE_NOTE: graphical input, screenshots and performance require the documented local graphical run\n'
