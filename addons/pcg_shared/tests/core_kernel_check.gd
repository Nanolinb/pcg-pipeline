extends SceneTree

# v0.14 公共内核专项测试的独立入口。
# 运行：Godot --headless --path <消费者工程> -s res://addons/pcg_shared/tests/core_kernel_check.gd
# 任一检查失败打印 CORE_RESULT: FAIL 并以非零码退出。

func _initialize() -> void:
	print("CORE_BEGIN: pcg_shared kernel checks")
	var script: GDScript = load("res://addons/pcg_shared/tests/core_kernel_checks.gd")
	if script == null:
		print("CORE_RESULT_FAIL: cannot load core_kernel_checks.gd")
		print("CORE_RESULT: FAIL")
		quit(1)
		return
	var checks: RefCounted = script.new()
	var result: Dictionary = checks.run("CORE")
	print("CORE_CHECKS: %d run, %d failed" % [int(result["checks_run"]), (result["failures"] as Array).size()])
	if (result["failures"] as Array).is_empty():
		print("CORE_RESULT: PASS")
		quit(0)
	else:
		print("CORE_RESULT: FAIL")
		quit(1)
