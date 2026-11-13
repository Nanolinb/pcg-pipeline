@tool
class_name PCGMeshBuildUtil
extends RefCounted

# 网格构建纯函数共享件：盒体拼装、顶点数组封包、多边形面/四边形发射与三角计数。
# 自 building_mesh_factory / skybridge_generator / building_generator / building_workbench
# 收敛而来，几何逐点等价：顶点、法线、UV 与索引的发射顺序与原实现完全一致。

static func boxes(parts: Array) -> ArrayMesh:
	var surface := SurfaceTool.new()
	surface.begin(Mesh.PRIMITIVE_TRIANGLES)
	for part in parts:
		var box := BoxMesh.new()
		box.size = part["size"]
		var basis: Basis = part.get("basis", Basis.IDENTITY)
		surface.append_from(box, 0, Transform3D(basis, part["center"]))
	return surface.commit()

static func mesh(vertices: PackedVector3Array, normals: PackedVector3Array,
			uvs: PackedVector2Array, indices: PackedInt32Array) -> ArrayMesh:
	var arrays: Array = []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = vertices
	arrays[Mesh.ARRAY_NORMAL] = normals
	arrays[Mesh.ARRAY_TEX_UV] = uvs
	arrays[Mesh.ARRAY_INDEX] = indices
	var result := ArrayMesh.new()
	result.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	return result

static func add_face(vertices: PackedVector3Array, normals: PackedVector3Array,
			uvs: PackedVector2Array, indices: PackedInt32Array,
			points: PackedVector3Array, normal: Vector3, face_uvs: PackedVector2Array) -> void:
	for corner in range(1, points.size() - 1):
		for index in [0, corner, corner + 1]:
			indices.append(vertices.size())
			vertices.append(points[index])
			normals.append(normal)
			uvs.append(face_uvs[index])

static func add_quad(vertices: PackedVector3Array, normals: PackedVector3Array,
			uvs: PackedVector2Array, indices: PackedInt32Array,
			points: Array, quad_uvs: Array) -> void:
	var normal: Vector3 = (points[1] - points[0]).cross(points[3] - points[0]).normalized()
	for corner in [0, 1, 2, 0, 2, 3]:
		indices.append(vertices.size())
		vertices.append(points[corner])
		normals.append(normal)
		uvs.append(quad_uvs[corner])

# 三角计数：优先按索引数统计；无索引 surface 回退为顶点数/3（与 building_generator 原实现一致）。
static func triangle_count(mesh: Mesh) -> int:
	if mesh == null:
		return 0
	var count := 0
	for surface in mesh.get_surface_count():
		var arrays := mesh.surface_get_arrays(surface)
		var indices = arrays[Mesh.ARRAY_INDEX]
		count += int(indices.size() / 3) if indices != null else int(arrays[Mesh.ARRAY_VERTEX].size() / 3)
	return count
