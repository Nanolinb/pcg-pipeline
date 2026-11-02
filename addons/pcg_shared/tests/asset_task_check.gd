extends SceneTree

# v0.15 L0 资产任务专项测试的独立入口。
# 运行：Godot --headless --path <消费者工程> -s res://addons/pcg_shared/tests/asset_task_check.gd
# 任一检查失败打印 TASK_RESULT: FAIL 并以非零码退出。

func _initialize() -> void:
	print("TASK_BEGIN: pcg_shared asset task checks")
	var checks := PCGAssetTaskChecks.new()
	var result: Dictionary = checks.run("TASK")
	print("TASK_CHECKS: %d run, %d failed" % [int(result["checks_run"]), (result["failures"] as Array).size()])
	if (result["failures"] as Array).is_empty():
		print("TASK_RESULT: PASS")
		quit(0)
	else:
		print("TASK_RESULT: FAIL")
		quit(1)
