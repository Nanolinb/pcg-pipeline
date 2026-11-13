extends SceneTree

const MeshBuildUtil = preload("res://addons/pcg_shared/mesh_build_util.gd")

var failures := PackedStringArray()
var checks := 0

func _initialize() -> void:
	call_deferred("_run")

func _run() -> void:
	_test_boxes_matches_reference()
	_test_mesh_roundtrip()
	_test_add_face_fan()
	_test_add_quad_matches_add_face()
	_test_triangle_count()
	_finish()

func _test_boxes_matches_reference() -> void:
	var parts: Array = [
		{"size": Vector3(1.0, 2.0, 3.0), "center": Vector3(0.5, -0.5, 1.0)},
		{"size": Vector3(0.4, 0.6, 0.8), "center": Vector3(-1.0, 2.0, 0.0),
			"basis": Basis(Vector3.RIGHT, deg_to_rad(32.0))},
	]
	var built: ArrayMesh = MeshBuildUtil.boxes(parts)
	var reference := SurfaceTool.new()
	reference.begin(Mesh.PRIMITIVE_TRIANGLES)
	for part in parts:
		var box := BoxMesh.new()
		box.size = part["size"]
		reference.append_from(box, 0, Transform3D(part.get("basis", Basis.IDENTITY), part["center"]))
	var expected: ArrayMesh = reference.commit()
	_check(built.get_surface_count() == 1, "boxes 应输出单 surface")
	_check(MeshBuildUtil.triangle_count(built) == 24, "两个盒体应为 24 个三角形")
	_check_arrays_equal(built.surface_get_arrays(0), expected.surface_get_arrays(0), "boxes 逐点等价")

func _test_mesh_roundtrip() -> void:
	var vertices := PackedVector3Array([Vector3(0, 0, 0), Vector3(1, 0, 0), Vector3(0, 1, 0)])
	var normals := PackedVector3Array([Vector3.UP, Vector3.UP, Vector3.UP])
	var uvs := PackedVector2Array([Vector2.ZERO, Vector2.RIGHT, Vector2.UP])
	var indices := PackedInt32Array([0, 1, 2])
	var built: ArrayMesh = MeshBuildUtil.mesh(vertices, normals, uvs, indices)
	var arrays := built.surface_get_arrays(0)
	_check(arrays[Mesh.ARRAY_VERTEX] == vertices and arrays[Mesh.ARRAY_TEX_UV] == uvs
		and arrays[Mesh.ARRAY_INDEX] == indices,
		"mesh 应原样封包顶点/UV/索引")
	# 引擎对法线做量化存储，逐点比较改为近似比较。
	var stored_normals: PackedVector3Array = arrays[Mesh.ARRAY_NORMAL]
	var normals_close := stored_normals.size() == normals.size()
	for i in normals.size():
		normals_close = normals_close and stored_normals[i].distance_to(normals[i]) < 0.001
	_check(normals_close, "mesh 法线应在引擎量化误差内保持一致")

func _test_add_face_fan() -> void:
	var points := PackedVector3Array([
		Vector3(0, 0, 0), Vector3(1, 0, 0), Vector3(1.5, 1, 0), Vector3(0.5, 2, 0), Vector3(-0.5, 1, 0),
	])
	var face_uvs := PackedVector2Array([
		Vector2(0, 0), Vector2(1, 0), Vector2(1.5, 1), Vector2(0.5, 2), Vector2(-0.5, 1),
	])
	var vertices := PackedVector3Array()
	var normals := PackedVector3Array()
	var uvs := PackedVector2Array()
	var indices := PackedInt32Array()
	MeshBuildUtil.add_face(vertices, normals, uvs, indices, points, Vector3.BACK, face_uvs)
	_check(indices == PackedInt32Array([0, 1, 2, 3, 4, 5, 6, 7, 8]), "五边形面应扇形展开为 3 个三角形")
	_check(vertices.size() == 9 and normals.size() == 9 and uvs.size() == 9, "每个角点应写入顶点/法线/UV")
	var expected_order := [0, 1, 2, 0, 2, 3, 0, 3, 4]
	for i in expected_order.size():
		_check(vertices[i] == points[expected_order[i]] and uvs[i] == face_uvs[expected_order[i]],
			"扇形展开第 %d 点应来自角点 %d" % [i, expected_order[i]])

func _test_add_quad_matches_add_face() -> void:
	var points: Array = [Vector3(0, 0, 0), Vector3(2, 0, 1), Vector3(2, 1, 1), Vector3(0, 1, 0)]
	var quad_uvs: Array = [Vector2(0, 0), Vector2(2, 0), Vector2(2, 1), Vector2(0, 1)]
	var normal: Vector3 = (points[1] - points[0]).cross(points[3] - points[0]).normalized()
	var quad_v := PackedVector3Array()
	var quad_n := PackedVector3Array()
	var quad_uv := PackedVector2Array()
	var quad_i := PackedInt32Array()
	MeshBuildUtil.add_quad(quad_v, quad_n, quad_uv, quad_i, points, quad_uvs)
	var face_v := PackedVector3Array()
	var face_n := PackedVector3Array()
	var face_uv := PackedVector2Array()
	var face_i := PackedInt32Array()
	MeshBuildUtil.add_face(face_v, face_n, face_uv, face_i,
		PackedVector3Array(points), normal, PackedVector2Array(quad_uvs))
	_check(quad_v == face_v and quad_n == face_n and quad_uv == face_uv and quad_i == face_i,
		"同一四边形 add_quad 与 add_face（显式法线）应逐点一致")
	_check(quad_i == PackedInt32Array([0, 1, 2, 3, 4, 5]), "add_quad 应按 0,1,2 / 0,2,3 发射两个三角形")

func _test_triangle_count() -> void:
	var box: ArrayMesh = MeshBuildUtil.boxes([{"size": Vector3.ONE, "center": Vector3.ZERO}])
	_check(MeshBuildUtil.triangle_count(box) == 12, "单个盒体应为 12 个三角形")
	var multi := MeshBuildUtil.boxes([{"size": Vector3.ONE, "center": Vector3.ZERO}])
	multi.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES,
		MeshBuildUtil.boxes([{"size": Vector3.ONE, "center": Vector3(2, 0, 0)}]).surface_get_arrays(0))
	_check(MeshBuildUtil.triangle_count(multi) == 24, "多 surface 应累计三角数")
	var arrays: Array = []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = PackedVector3Array([
		Vector3(0, 0, 0), Vector3(1, 0, 0), Vector3(0, 1, 0), Vector3(1, 1, 0),
	])
	var unindexed := ArrayMesh.new()
	unindexed.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	_check(MeshBuildUtil.triangle_count(unindexed) == 1, "无索引 surface 应回退为顶点数/3")
	_check(MeshBuildUtil.triangle_count(null) == 0, "空 Mesh 应计 0 个三角形")

func _check_arrays_equal(actual: Array, expected: Array, label: String) -> void:
	_check(actual[Mesh.ARRAY_VERTEX] == expected[Mesh.ARRAY_VERTEX], "%s：顶点数组不一致" % label)
	_check(actual[Mesh.ARRAY_NORMAL] == expected[Mesh.ARRAY_NORMAL], "%s：法线数组不一致" % label)
	_check(actual[Mesh.ARRAY_TEX_UV] == expected[Mesh.ARRAY_TEX_UV], "%s：UV 数组不一致" % label)
	_check(actual[Mesh.ARRAY_INDEX] == expected[Mesh.ARRAY_INDEX], "%s：索引数组不一致" % label)

func _check(condition: bool, message: String) -> void:
	checks += 1
	if not condition:
		failures.append(message)

func _finish() -> void:
	if failures.is_empty():
		print("MESH_BUILD_UTIL_RESULT: PASS checks=%d" % checks)
		quit(0)
	else:
		for failure in failures:
			push_error("MESH_BUILD_UTIL_TEST: " + failure)
		print("MESH_BUILD_UTIL_RESULT: FAIL checks=%d" % checks)
		quit(1)
