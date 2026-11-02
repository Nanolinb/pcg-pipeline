extends SceneTree

# v0.16 L1 几何验收与校准专项测试的独立入口。
# 运行：Godot --headless --path <消费者工程> -s res://addons/pcg_shared/tests/mesh_inspector_check.gd
# 任一检查失败打印 MESH_RESULT: FAIL 并以非零码退出。

func _initialize() -> void:
	print("MESH_BEGIN: pcg_shared mesh inspector checks")
	var checks := PCGMeshInspectorChecks.new()
	var result: Dictionary = checks.run("MESH")
	print("MESH_CHECKS: %d run, %d failed" % [int(result["checks_run"]), (result["failures"] as Array).size()])
	if (result["failures"] as Array).is_empty():
		print("MESH_RESULT: PASS")
		quit(0)
	else:
		print("MESH_RESULT: FAIL")
		quit(1)
