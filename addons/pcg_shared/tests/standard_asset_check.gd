extends SceneTree

# v0.16 L1 标准资产与试装发布专项测试入口（共享包内单源）。
# 运行: Godot --headless --path <工程> -s res://addons/pcg_shared/tests/standard_asset_check.gd
# 覆盖发布/重载往返、真实 LOD、试装变换（三种宿主）、白盒/碰撞输出、
# 缺失依赖拒绝；任一检查失败返回非零退出码。

const CHECKS_SCRIPT_PATH := "res://addons/pcg_shared/tests/standard_asset_checks.gd"
const LOG_PREFIX := "STANDARD_ASSET"


func _initialize() -> void:
	print("STANDARD_ASSET_BEGIN: standard asset publish/reload/trial-fit checks")
	var script: GDScript = load(CHECKS_SCRIPT_PATH)
	if script == null:
		print("STANDARD_ASSET_CHECK_FAIL: checks script compiles (%s)" % CHECKS_SCRIPT_PATH)
		print("STANDARD_ASSET_RESULT: FAIL")
		quit(1)
		return
	var checks: RefCounted = script.new()
	var result: Dictionary = checks.run(LOG_PREFIX)
	print("STANDARD_ASSET_CHECKS: %d run, %d failed" % [int(result["checks_run"]), (result["failures"] as Array).size()])
	if (result["failures"] as Array).is_empty():
		print("STANDARD_ASSET_RESULT: PASS")
		quit(0)
	else:
		for failure in result["failures"]:
			print("STANDARD_ASSET_RESULT_FAIL: " + String(failure))
		quit(1)
