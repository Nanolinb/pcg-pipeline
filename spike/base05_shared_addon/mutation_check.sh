#!/usr/bin/env bash
# 非零失败路径验证：把共享模块复制到一次性目录，篡改一个黄金常量后运行
# 独立内核测试入口，确认 CORE_RESULT: FAIL 与非零退出；再修回归确认恢复全绿。
set -u

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
GODOT_BIN="${GODOT_BIN:-/Applications/Godot.app/Contents/MacOS/Godot}"
CONSUMER="$ROOT_DIR/spike/base05_shared_addon/consumer"
TMP_DIR="$(mktemp -d "$ROOT_DIR/spike/base05_shared_addon/work/mutation.XXXXXX")"
trap 'rm -rf "$TMP_DIR"' EXIT

rsync -a --exclude='.godot' --exclude='.git' "$CONSUMER"/ "$TMP_DIR/consumer/"
rm "$TMP_DIR/consumer/addons/pcg_shared"
cp -R "$ROOT_DIR/shared/addons/pcg_shared" "$TMP_DIR/consumer/addons/pcg_shared"

TESTS="$TMP_DIR/consumer/addons/pcg_shared/tests/core_kernel_checks.gd"

echo "MUTATION_STEP: inject regression (RNG golden seed off by one)"
sed -i '' 's/GOLDEN_SEED_MASTER42_W1 := -6724053372761431311/GOLDEN_SEED_MASTER42_W1 := -6724053372761431312/' "$TESTS"
grep -c "11722690700948120306" "$TESTS" >/dev/null || true

"$GODOT_BIN" --headless --path "$TMP_DIR/consumer" --import >/dev/null 2>&1 || true
set +e
"$GODOT_BIN" --headless --path "$TMP_DIR/consumer" -s res://addons/pcg_shared/tests/core_kernel_check.gd >"$TMP_DIR/mutated.log" 2>&1
MUTATED_EXIT=$?
set -e
if grep -q "CORE_RESULT: PASS" "$TMP_DIR/mutated.log" || [[ "$MUTATED_EXIT" -eq 0 ]]; then
	echo "MUTATION_FAIL: injected regression did not fail the gate (exit=$MUTATED_EXIT)" >&2
	tail -n 10 "$TMP_DIR/mutated.log" >&2
	exit 1
fi
grep -E '^CORE_CHECK_FAIL' "$TMP_DIR/mutated.log" || true
echo "MUTATION_PASS: injected regression produced CORE_RESULT: FAIL and non-zero exit ($MUTATED_EXIT)"

echo "MUTATION_STEP: revert regression, expect green again"
sed -i '' 's/GOLDEN_SEED_MASTER42_W1 := -6724053372761431312/GOLDEN_SEED_MASTER42_W1 := -6724053372761431311/' "$TESTS"
"$GODOT_BIN" --headless --path "$TMP_DIR/consumer" -s res://addons/pcg_shared/tests/core_kernel_check.gd >"$TMP_DIR/reverted.log" 2>&1 || true
if grep -q "CORE_RESULT: PASS" "$TMP_DIR/reverted.log"; then
	echo "MUTATION_PASS: reverted run is green again"
else
	echo "MUTATION_FAIL: reverted run did not pass" >&2
	tail -n 10 "$TMP_DIR/reverted.log" >&2
	exit 1
fi
