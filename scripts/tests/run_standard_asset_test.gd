extends SceneTree

# v0.16 L1 标准资产与试装发布专项测试（根工程 gate 入口，headless）。
# 运行: Godot --headless --path <根工程> -s scripts/tests/run_standard_asset_test.gd
# 与共享包内 tests/standard_asset_check.gd 共用同一份 PCGStandardAssetChecks；
# 以 STD_ASSET_RESULT: PASS 标记为准，任一检查失败返回非零退出码。

const CHECKS_SCRIPT_PATH := "res://addons/pcg_shared/tests/standard_asset_checks.gd"


func _initialize() -> void:
	print("STD_ASSET_BEGIN: standard asset publish/reload/trial-fit checks")
	var script: GDScript = load(CHECKS_SCRIPT_PATH)
	if script == null:
		print("STD_ASSET_CHECK_FAIL: checks script compiles (%s)" % CHECKS_SCRIPT_PATH)
		print("STD_ASSET_RESULT: FAIL")
		quit(1)
		return
	var checks: RefCounted = script.new()
	var result: Dictionary = checks.run("STD_ASSET")
	print("STD_ASSET_CHECKS: %d run, %d failed" % [int(result["checks_run"]), (result["failures"] as Array).size()])
	if (result["failures"] as Array).is_empty():
		print("STD_ASSET_RESULT: PASS")
		quit(0)
	else:
		for failure in result["failures"]:
			print("STD_ASSET_RESULT_FAIL: " + String(failure))
		quit(1)
