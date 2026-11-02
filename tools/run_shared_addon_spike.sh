#!/usr/bin/env bash
# BASE-05 共享载体 Spike 验证（可重复运行）。
#
# 流程：把根工程、PipeWeaver、最小第三方消费者各复制到一次性临时目录
# （不复制 .godot/，等价于清理缓存），将共享模块链接指向工作区
# shared/addons/pcg_shared 真实文件，headless --import 重导入后运行
# 三工程共用的 spike_check.gd。任一消费者失败返回非零退出码。
# 原工程的 .godot/ 缓存不会被修改或删除。
set -u

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
GODOT_BIN="${GODOT_BIN:-}"
SPIKE_SCRIPT="res://addons/pcg_shared/tests/spike_check.gd"

if [[ -z "$GODOT_BIN" ]]; then
	if [[ -x /Applications/Godot.app/Contents/MacOS/Godot ]]; then
		GODOT_BIN=/Applications/Godot.app/Contents/MacOS/Godot
	elif command -v godot >/dev/null 2>&1; then
		GODOT_BIN="$(command -v godot)"
	else
		printf 'SPIKE_FAIL: Godot executable not found; set GODOT_BIN\n' >&2
		exit 1
	fi
fi

WORK_DIR="$ROOT_DIR/spike/base05_shared_addon/work"
mkdir -p "$WORK_DIR"
TMP_DIR="$(mktemp -d "$WORK_DIR/run.XXXXXX")"
trap 'rm -rf "$TMP_DIR"' EXIT

failures=0

run_consumer() {
	local name="$1"
	local src="$2"
	local link_dir="$3"   # temp project 内 addons 目录
	local link_target="$4" # 指向工作区共享模块的绝对路径
	local proj="$TMP_DIR/$name"

	printf '\nSPIKE_BEGIN: %s\n' "$name"
	if ! rsync -a --exclude='.godot' --exclude='.git' --exclude='PipeWeaver' \
		--exclude='spike' --exclude='shared' --exclude='reports' \
		--exclude='docs' --exclude='tools' "$src"/ "$proj"/; then
		printf 'SPIKE_FAIL: %s copy failed\n' "$name" >&2
		failures=$((failures + 1))
		return
	fi
	mkdir -p "$link_dir"
	rm -rf "$link_dir/pcg_shared"
	ln -s "$link_target" "$link_dir/pcg_shared"

	# 清理缓存后的重导入（在一次性副本中进行）。
	if ! "$GODOT_BIN" --headless --path "$proj" --import >"$proj/import.log" 2>&1; then
		printf 'SPIKE_FAIL: %s reimport failed (see log below)\n' "$name" >&2
		tail -n 20 "$proj/import.log" >&2
		failures=$((failures + 1))
		return
	fi

	# Godot 的 -s 模式在脚本加载/解析失败时仍可能返回 0，
	# 因此以日志中的 SPIKE_RESULT: PASS 为准，而非进程退出码。
	"$GODOT_BIN" --headless --path "$proj" -s "$SPIKE_SCRIPT" >"$proj/spike.log" 2>&1 || true
	if grep -q "SPIKE_RESULT: PASS" "$proj/spike.log"; then
		grep -E '^SPIKE_' "$proj/spike.log" || true
		printf 'SPIKE_PASS: %s\n' "$name"
	else
		printf 'SPIKE_FAIL: %s checks failed (log below)\n' "$name" >&2
		tail -n 40 "$proj/spike.log" >&2
		failures=$((failures + 1))
	fi
}

run_consumer "surface_component" "$ROOT_DIR" "$TMP_DIR/surface_component/addons" "$ROOT_DIR/addons/pcg_shared"
run_consumer "pipeweaver" "$ROOT_DIR/PipeWeaver" "$TMP_DIR/pipeweaver/addons" "$ROOT_DIR/addons/pcg_shared"
run_consumer "third_party_consumer" "$ROOT_DIR/spike/base05_shared_addon/consumer" "$TMP_DIR/third_party_consumer/addons" "$ROOT_DIR/addons/pcg_shared"

if [[ "$failures" -ne 0 ]]; then
	printf '\nSPIKE_FAIL: %d consumer(s) failed\n' "$failures" >&2
	exit 1
fi

printf '\nSPIKE_PASS: all three consumers load the shared addon from a single source\n'
printf 'SPIKE_NOTE: 三个消费者均在一次性副本中完成 .godot 清理重导入；原工程缓存未动\n'
