extends SceneTree

# v0.16 L1 网格 fixtures 导出（一次性/可重复）。
# 运行: Godot --headless --path <根工程> -s scripts/tests/export_mesh_fixtures.gd
# 用 PCGMeshFixtureFactory 重建全部 fixtures 并以 .tres 落盘到 assets/raw，
# 供 L1 工作台与专项测试共用同一份资产数据。

const FIXTURE_DIR := "res://assets/raw"

func _initialize() -> void:
	print("MESH_FIXTURE_EXPORT_BEGIN")
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(FIXTURE_DIR))
	var failed := false
	for name in PCGMeshFixtureFactory.FIXTURE_NAMES:
		var mesh := PCGMeshFixtureFactory.build_fixture(name)
		var path := "%s/%s.tres" % [FIXTURE_DIR, name]
		var err := ResourceSaver.save(mesh, path)
		if err != OK:
			print("MESH_FIXTURE_EXPORT_FAIL: %s (err=%d)" % [path, err])
			failed = true
		else:
			print("MESH_FIXTURE_EXPORTED: %s" % path)
	print("MESH_FIXTURE_EXPORT_RESULT: %s" % ("FAIL" if failed else "PASS"))
	quit(1 if failed else 0)
