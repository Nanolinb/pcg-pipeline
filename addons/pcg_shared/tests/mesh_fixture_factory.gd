@tool
class_name PCGMeshFixtureFactory
extends RefCounted

# v0.16 L1 几何验收测试 fixtures：程序化构建有效/开放/退化/UV缺失/非流形
# 五种网格。scripts/tests/export_mesh_fixtures.gd 用本工厂把 fixtures 落盘为
# assets/raw/*.tres；专项测试同时加载落盘文件并核对关键统计，
# 保证“被验收的资产”与“测试里的资产”是同一份数据。

const FIXTURE_NAMES: Array[String] = [
	"valid_crate", "open_crate", "degenerate_crate", "uv_missing_crate",
	"non_manifold_fan", "beam_block",
]


static func build_fixture(name: String) -> ArrayMesh:
	match name:
		"valid_crate":
			return _build_cube("valid_crate", Vector3.ONE, false, true, true)
		"open_crate":
			return _build_cube("open_crate", Vector3.ONE, true, true, true)
		"degenerate_crate":
			return _build_degenerate_crate()
		"uv_missing_crate":
			return _build_cube("uv_missing_crate", Vector3.ONE, false, false, true)
		"non_manifold_fan":
			return _build_non_manifold_fan()
		"beam_block":
			return _build_cube("beam_block", Vector3(1.0, 2.0, 4.0), false, true, true)
	push_error("unknown fixture: " + name)
	return null


static func build_nan_mesh() -> ArrayMesh:
	var mesh := ArrayMesh.new()
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = PackedVector3Array([
		Vector3(0, 0, 0), Vector3(NAN, 0, 0), Vector3(0, 1, 0),
	])
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	return mesh


static func build_single_triangle() -> ArrayMesh:
	# 3 条边全是边界边（100% 开放），用于“严重开放拒绝校准”用例。
	var mesh := ArrayMesh.new()
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = PackedVector3Array([
		Vector3(0, 0, 0), Vector3(1, 0, 0), Vector3(0, 1, 0),
	])
	arrays[Mesh.ARRAY_NORMAL] = PackedVector3Array([
		Vector3(0, 0, 1), Vector3(0, 0, 1), Vector3(0, 0, 1),
	])
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	return mesh


static func _build_cube(resource_name: String, size: Vector3, skip_top: bool,
		with_uv: bool, with_normals: bool) -> ArrayMesh:
	var verts := PackedVector3Array()
	var normals := PackedVector3Array()
	var uvs := PackedVector2Array()
	var indices := PackedInt32Array()
	var h := size * 0.5
	var faces: Array = [
		[Vector3(h.x, -h.y, -h.z), Vector3(h.x, -h.y, h.z), Vector3(h.x, h.y, h.z), Vector3(h.x, h.y, -h.z), Vector3.RIGHT],
		[Vector3(-h.x, -h.y, h.z), Vector3(-h.x, -h.y, -h.z), Vector3(-h.x, h.y, -h.z), Vector3(-h.x, h.y, h.z), Vector3.LEFT],
		[Vector3(-h.x, -h.y, h.z), Vector3(h.x, -h.y, h.z), Vector3(h.x, -h.y, -h.z), Vector3(-h.x, -h.y, -h.z), Vector3.DOWN],
	]
	if not skip_top:
		faces.append([Vector3(-h.x, h.y, -h.z), Vector3(-h.x, h.y, h.z), Vector3(h.x, h.y, h.z), Vector3(h.x, h.y, -h.z), Vector3.UP])
	faces.append_array([
		[Vector3(-h.x, -h.y, h.z), Vector3(-h.x, h.y, h.z), Vector3(h.x, h.y, h.z), Vector3(h.x, -h.y, h.z), Vector3.BACK],
		[Vector3(h.x, -h.y, -h.z), Vector3(h.x, h.y, -h.z), Vector3(-h.x, h.y, -h.z), Vector3(-h.x, -h.y, -h.z), Vector3.FORWARD],
	])
	for face in faces:
		_add_quad(verts, normals, uvs, indices,
			face[0], face[1], face[2], face[3], face[4], with_uv, with_normals)
	return _assemble(resource_name, verts, normals, uvs, indices, with_uv, with_normals)


static func _build_degenerate_crate() -> ArrayMesh:
	# 封闭立方体 + 一个两顶点重合的零面积三角：既触发 zero-area 报错，
	# 又保持整体封闭，便于校准清理后仍能产出可用网格。
	var verts := PackedVector3Array()
	var normals := PackedVector3Array()
	var uvs := PackedVector2Array()
	var indices := PackedInt32Array()
	var h := Vector3.ONE * 0.5
	var faces: Array = [
		[Vector3(h.x, -h.y, -h.z), Vector3(h.x, -h.y, h.z), Vector3(h.x, h.y, h.z), Vector3(h.x, h.y, -h.z), Vector3.RIGHT],
		[Vector3(-h.x, -h.y, h.z), Vector3(-h.x, -h.y, -h.z), Vector3(-h.x, h.y, -h.z), Vector3(-h.x, h.y, h.z), Vector3.LEFT],
		[Vector3(-h.x, -h.y, h.z), Vector3(h.x, -h.y, h.z), Vector3(h.x, -h.y, -h.z), Vector3(-h.x, -h.y, -h.z), Vector3.DOWN],
		[Vector3(-h.x, h.y, -h.z), Vector3(-h.x, h.y, h.z), Vector3(h.x, h.y, h.z), Vector3(h.x, h.y, -h.z), Vector3.UP],
		[Vector3(-h.x, -h.y, h.z), Vector3(-h.x, h.y, h.z), Vector3(h.x, h.y, h.z), Vector3(h.x, -h.y, h.z), Vector3.BACK],
		[Vector3(h.x, -h.y, -h.z), Vector3(h.x, h.y, -h.z), Vector3(-h.x, h.y, -h.z), Vector3(-h.x, -h.y, -h.z), Vector3.FORWARD],
	]
	for face in faces:
		_add_quad(verts, normals, uvs, indices,
			face[0], face[1], face[2], face[3], face[4], true, true)
	var spike := Vector3(h.x, h.y, h.z)
	_add_tri(verts, normals, uvs, indices, spike, spike + Vector3.UP, spike + Vector3.UP, Vector3.RIGHT)
	return _assemble("degenerate_crate", verts, normals, uvs, indices, true, true)


static func _build_non_manifold_fan() -> ArrayMesh:
	var a := Vector3(-0.5, -0.5, 0)
	var b := Vector3(0.5, -0.5, 0)
	var c := Vector3(0.5, 0.5, 0)
	var d := Vector3(-0.5, 0.5, 0)
	var e := Vector3(0, 0, 0.5)
	var verts := PackedVector3Array()
	var normals := PackedVector3Array()
	var uvs := PackedVector2Array()
	var indices := PackedInt32Array()
	_add_tri(verts, normals, uvs, indices, a, b, c, Vector3.FORWARD)
	_add_tri(verts, normals, uvs, indices, a, c, d, Vector3.FORWARD)
	_add_tri(verts, normals, uvs, indices, a, c, e, Vector3.UP)  # 边 a-c 被三个三角共享
	return _assemble("non_manifold_fan", verts, normals, uvs, indices, true, true)


static func _add_quad(verts: PackedVector3Array, normals: PackedVector3Array,
		uvs: PackedVector2Array, indices: PackedInt32Array,
		p0: Vector3, p1: Vector3, p2: Vector3, p3: Vector3,
		normal: Vector3, with_uv: bool, with_normals: bool) -> void:
	var winding: Array[Vector3] = [p0, p1, p2, p3]
	if (p1 - p0).cross(p2 - p0).dot(normal) > 0.0:
		winding = [p0, p3, p2, p1]
	var base := verts.size()
	var quad_uvs: Array[Vector2] = [Vector2(0, 1), Vector2(1, 1), Vector2(1, 0), Vector2(0, 0)]
	for i in 4:
		verts.append(winding[i])
		if with_normals:
			normals.append(normal)
		if with_uv:
			uvs.append(quad_uvs[i])
	indices.append_array([base, base + 1, base + 2, base, base + 2, base + 3])


static func _add_tri(verts: PackedVector3Array, normals: PackedVector3Array,
		uvs: PackedVector2Array, indices: PackedInt32Array,
		p0: Vector3, p1: Vector3, p2: Vector3, hint: Vector3) -> void:
	var winding: Array[Vector3] = [p0, p1, p2]
	if (p1 - p0).cross(p2 - p0).dot(hint) > 0.0:
		winding = [p0, p2, p1]
	var base := verts.size()
	var normal := (winding[1] - winding[0]).cross(winding[2] - winding[0]).normalized()
	for i in 3:
		verts.append(winding[i])
		normals.append(normal)
		uvs.append(Vector2(float(i == 1), float(i == 2)))
	indices.append_array([base, base + 1, base + 2])


static func _assemble(resource_name: String, verts: PackedVector3Array,
		normals: PackedVector3Array, uvs: PackedVector2Array,
		indices: PackedInt32Array, with_uv: bool, with_normals: bool) -> ArrayMesh:
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = verts
	arrays[Mesh.ARRAY_INDEX] = indices
	if with_normals:
		arrays[Mesh.ARRAY_NORMAL] = normals
	if with_uv:
		arrays[Mesh.ARRAY_TEX_UV] = uvs
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	var material := StandardMaterial3D.new()
	material.resource_name = resource_name + "_material"
	mesh.surface_set_material(0, material)
	mesh.resource_name = resource_name
	return mesh
