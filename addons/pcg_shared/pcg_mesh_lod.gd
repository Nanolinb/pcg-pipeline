@tool
class_name PCGMeshLod
extends RefCounted

# v0.16 L1 标准资产：自动 LOD 生成。
#
# 自动 LOD 必须真实：本类只做顶点聚类（vertex clustering）减面，
# 绝不把 LOD0 静默复制充当 LOD1/2。流程：
#   1. capability() 能力检查：只接受纯三角形索引网格；不通过则调用方
#      必须提供显式 LOD（PCGStandardAsset.lod1_mesh/lod2_mesh）。
#   2. decimate() 以目标面数二分搜索网格单元尺寸，输出真实减面后的
#      ArrayMesh（平顶法线、仅 POSITION/NORMAL/INDEX）。
# 面数已低于预算时返回原网格引用并把 method 标为 passthrough_below_budget，
# 状态对调用方完全可见，不算“静默复制”。

const MIN_DECIMATABLE_FACES := 4


## 能力检查。返回 {ok, errors, faces, vertices}。
static func capability(mesh: ArrayMesh) -> Dictionary:
	var errors: Array[String] = []
	var faces := 0
	var vertices := 0
	if mesh == null:
		errors.append("mesh is null")
	elif mesh.get_surface_count() == 0:
		errors.append("mesh has no surfaces")
	else:
		for surface_index in mesh.get_surface_count():
			if mesh.surface_get_primitive_type(surface_index) != Mesh.PRIMITIVE_TRIANGLES:
				errors.append("surface %d is not PRIMITIVE_TRIANGLES" % surface_index)
				continue
			var arrays := mesh.surface_get_arrays(surface_index)
			var indices: PackedInt32Array = arrays[Mesh.ARRAY_INDEX]
			var positions: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
			if indices.is_empty():
				errors.append("surface %d is not indexed" % surface_index)
				continue
			if indices.size() % 3 != 0:
				errors.append("surface %d index count %d is not a multiple of 3"
					% [surface_index, indices.size()])
				continue
			faces += indices.size() / 3
			vertices += positions.size()
		if faces > 0 and faces < MIN_DECIMATABLE_FACES:
			errors.append("mesh has only %d faces (<%d), too coarse to decimate"
				% [faces, MIN_DECIMATABLE_FACES])
	return {"ok": errors.is_empty(), "errors": errors, "faces": faces, "vertices": vertices}


## 真实减面到 target_faces 以内。返回
## {ok, mesh, faces_in, faces_out, cell_size, method, errors}。
## method ∈ {"vertex_clustering", "passthrough_below_budget"}。
static func decimate(mesh: ArrayMesh, target_faces: int) -> Dictionary:
	if target_faces < 1:
		return {"ok": false, "mesh": null, "faces_in": 0, "faces_out": 0,
			"cell_size": 0.0, "method": "", "errors": ["target_faces must be >= 1"]}
	var cap: Dictionary = capability(mesh)
	if not cap["ok"]:
		return {"ok": false, "mesh": null, "faces_in": cap["faces"], "faces_out": 0,
			"cell_size": 0.0, "method": "",
			"errors": ["auto LOD capability check failed: %s; supply explicit LOD meshes"
				% "; ".join(cap["errors"])]}
	var faces_in: int = cap["faces"]
	if faces_in <= target_faces:
		return {"ok": true, "mesh": mesh, "faces_in": faces_in, "faces_out": faces_in,
			"cell_size": 0.0, "method": "passthrough_below_budget", "errors": []}
	var triangles := _collect_triangles(mesh)
	var aabb := mesh.get_aabb()
	var diagonal := maxf(aabb.size.length(), 0.0001)
	# 几何扫描找首个 faces <= target 的 cell；若直接坍缩到 0 面
	# （跳过目标窗口），退而求其次：取全程最小非空聚类（仍是真实减面，
	# 绝不复制 LOD0），并在 warning 里明确披露未达目标。
	var cell := diagonal / 32.0
	var best_faces := 0
	var best_cell := 0.0
	var best_tris: Array = []
	var min_faces := faces_in + 1
	var min_tris: Array = []
	var min_cell := 0.0
	var lo_cell := 0.0
	var hi_cell := 0.0
	var guard := 0
	while guard < 32 and cell <= diagonal * 8.0:
		guard += 1
		var clustered := _cluster_pass(triangles, cell)
		if clustered.is_empty():
			hi_cell = cell
			break
		if clustered.size() < min_faces:
			min_faces = clustered.size()
			min_tris = clustered
			min_cell = cell
		if clustered.size() <= target_faces:
			best_faces = clustered.size()
			best_cell = cell
			best_tris = clustered
			break
		lo_cell = cell
		cell *= 2.0
	if best_cell == 0.0 and hi_cell > 0.0 and lo_cell > 0.0:
		for _i in 24:
			var mid := (lo_cell + hi_cell) * 0.5
			var clustered := _cluster_pass(triangles, mid)
			if clustered.is_empty():
				hi_cell = mid
				continue
			if clustered.size() < min_faces:
				min_faces = clustered.size()
				min_tris = clustered
				min_cell = mid
			if clustered.size() <= target_faces:
				best_faces = clustered.size()
				best_cell = mid
				best_tris = clustered
				break
			lo_cell = mid
	if best_cell == 0.0:
		if min_faces < faces_in and not min_tris.is_empty():
			return {"ok": true, "mesh": _build_mesh(min_tris), "faces_in": faces_in,
				"faces_out": min_faces, "cell_size": min_cell,
				"method": "vertex_clustering",
				"warning": "target %d faces unreachable (best %d); best-effort decimation"
					% [target_faces, min_faces], "errors": []}
		return {"ok": false, "mesh": null, "faces_in": faces_in, "faces_out": min_faces,
			"cell_size": min_cell, "method": "",
			"errors": ["vertex clustering could not reduce below %d faces; \
supply explicit LOD meshes" % faces_in]}
	return {"ok": true, "mesh": _build_mesh(best_tris), "faces_in": faces_in,
		"faces_out": best_tris.size(), "cell_size": best_cell,
		"method": "vertex_clustering", "warning": "", "errors": []}


static func _collect_triangles(mesh: ArrayMesh) -> Array:
	# 返回三角形顶点位置数组的数组（[[v0, v1, v2], ...]，全部展开为世界/网格局部坐标）。
	var triangles: Array = []
	for surface_index in mesh.get_surface_count():
		var arrays := mesh.surface_get_arrays(surface_index)
		var indices: PackedInt32Array = arrays[Mesh.ARRAY_INDEX]
		var positions: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
		var tri: Array = []
		for index in indices:
			tri.append(positions[index])
			if tri.size() == 3:
				triangles.append(tri)
				tri = []
	return triangles


static func _cluster_pass(triangles: Array, cell: float) -> Array:
	# 顶点聚类：cell 尺寸空间哈希 → 代表点取簇内平均 → 退化三角形丢弃。
	var sums := {}
	var counts := {}
	var order: Array = []
	for tri in triangles:
		for vertex in tri:
			var key := Vector3i(floori(vertex.x / cell), floori(vertex.y / cell),
				floori(vertex.z / cell))
			if not sums.has(key):
				sums[key] = vertex
				counts[key] = 1
				order.append(key)
			else:
				sums[key] += vertex
				counts[key] += 1
	var representatives := {}
	var index_of := {}
	var points := PackedVector3Array()
	for key in order:
		var point: Vector3 = sums[key] / float(counts[key])
		index_of[key] = points.size()
		points.append(point)
	var surviving: Array = []
	for tri in triangles:
		var mapped: Array = []
		var seen := {}
		for vertex in tri:
			var key := Vector3i(floori(vertex.x / cell), floori(vertex.y / cell),
				floori(vertex.z / cell))
			var idx: int = index_of[key]
			if not seen.has(idx):
				seen[idx] = true
				mapped.append(points[idx])
		if mapped.size() == 3:
			surviving.append(mapped)
	return surviving


static func _build_mesh(triangles: Array) -> ArrayMesh:
	# 平顶法线输出：每三角形 3 个独立顶点 + generate_normals。
	var surface_tool := SurfaceTool.new()
	surface_tool.begin(Mesh.PRIMITIVE_TRIANGLES)
	for tri in triangles:
		surface_tool.add_vertex(tri[0])
		surface_tool.add_vertex(tri[1])
		surface_tool.add_vertex(tri[2])
	surface_tool.index()
	surface_tool.generate_normals()
	return surface_tool.commit()
