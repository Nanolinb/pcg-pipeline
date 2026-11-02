@tool
class_name PCGAssetMeshInspector
extends RefCounted

# v0.16 L1 几何验收与校准：可见资产进入工作台前后的网格体检与规范化。
# inspect_mesh 只读体检，返回 ok/errors/warnings/stats/issues；
# calibrate_mesh 在体检基础上做真实变换（basis + root_offset）、
# 顶点焊接与退化三角清理，把网格规范到任务目标尺寸。
# 校准不做伪修复：非流形边直接拒绝，严重开放边界（>50% 边为边界）也拒绝，
# 轻微开放边界原样保留并在 actions 里显式声明。

const AREA_EPSILON := 1e-10
const NORMAL_EPSILON := 1e-6
const SIZE_TOLERANCE := 0.01
const OPEN_BOUNDARY_REFUSAL_FRACTION := 0.5


# ------------------------------------------------------------------ 体检

func inspect_mesh(mesh: Mesh, task: PCGAssetTask = null) -> Dictionary:
	var errors: Array[String] = []
	var warnings: Array[String] = []
	var issues: Array[Dictionary] = []
	var stats := {
		"surfaces": 0, "vertices": 0, "triangles": 0,
		"edges": 0, "boundary_edges": 0, "non_manifold_edges": 0,
		"degenerate_triangles": 0, "uv0_present": false, "normals_present": false,
		"aabb": AABB(), "aabb_size": Vector3.ZERO, "material_slots": 0,
	}
	if mesh == null:
		errors.append("mesh is null")
		return _pack(errors, warnings, issues, stats)
	if mesh is ArrayMesh and (mesh as ArrayMesh).get_faces().is_empty():
		warnings.append("mesh has no triangle faces")
	stats.surfaces = mesh.get_surface_count()
	if stats.surfaces == 0:
		errors.append("mesh has no surfaces")
		return _pack(errors, warnings, issues, stats)

	var edge_use := {}
	var saw_uv := false
	var saw_normals := false
	for surface_index in stats.surfaces:
		var arrays := mesh.surface_get_arrays(surface_index)
		var vertices: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
		var indices := PackedInt32Array()
		if arrays[Mesh.ARRAY_INDEX] != null:
			indices = arrays[Mesh.ARRAY_INDEX]
		if indices.is_empty():
			indices = _sequential_indices(vertices.size())
		stats.vertices += vertices.size()
		stats.material_slots += 1 if mesh.surface_get_material(surface_index) != null else 0
		if arrays[Mesh.ARRAY_TEX_UV] != null:
			saw_uv = true
		if arrays[Mesh.ARRAY_NORMAL] != null:
			saw_normals = true
		for vertex in vertices:
			if _has_nan(vertex):
				_add_issue(issues, errors, "error", "nan_vertices",
					"surface %d contains NaN vertices" % surface_index, surface_index)
				break
		var tri_count: int = int(indices.size() / 3)
		stats.triangles += tri_count
		for tri in tri_count:
			var i0: int = indices[tri * 3]
			var i1: int = indices[tri * 3 + 1]
			var i2: int = indices[tri * 3 + 2]
			if i0 >= vertices.size() or i1 >= vertices.size() or i2 >= vertices.size():
				_add_issue(issues, errors, "error", "index_out_of_range",
					"surface %d triangle %d references missing vertex" % [surface_index, tri], surface_index, tri)
				continue
			var area_sq := _triangle_area_squared(vertices[i0], vertices[i1], vertices[i2])
			if area_sq < AREA_EPSILON:
				stats.degenerate_triangles += 1
				_add_issue(issues, errors, "error", "zero_area_triangle",
					"surface %d triangle %d has zero area" % [surface_index, tri], surface_index, tri)
				continue  # 退化三角不参与边统计，避免自环边污染边界/流形计数
			for edge in [[i0, i1], [i1, i2], [i2, i0]]:
				var key := _edge_key(_pos_key(vertices[edge[0]]), _pos_key(vertices[edge[1]]))
				edge_use[key] = int(edge_use.get(key, 0)) + 1
		if not saw_uv:
			warnings.append("surface %d has no UV0" % surface_index)
		if not saw_normals:
			warnings.append("surface %d has no normals (viewer will compute flat normals)" % surface_index)

	stats.uv0_present = saw_uv
	stats.normals_present = saw_normals
	stats.edges = edge_use.size()
	for key in edge_use:
		var use_count: int = edge_use[key]
		if use_count == 1:
			stats.boundary_edges += 1
		elif use_count > 2:
			stats.non_manifold_edges += 1
	if stats.non_manifold_edges > 0:
		errors.append("mesh has %d non-manifold edges (used by >2 triangles)" % stats.non_manifold_edges)
	if stats.boundary_edges > 0:
		errors.append("mesh is open: %d of %d edges are boundary edges"
			% [stats.boundary_edges, stats.edges])
	if stats.degenerate_triangles > 0:
		errors.append("mesh has %d zero-area triangles" % stats.degenerate_triangles)

	stats.aabb = mesh.get_aabb()
	stats.aabb_size = stats.aabb.size
	for axis in 3:
		if stats.aabb.size[axis] <= 0.0:
			warnings.append("aabb has zero extent on axis %d" % axis)
			break

	if task != null:
		_inspect_against_task(stats, task, errors, warnings, issues)
	return _pack(errors, warnings, issues, stats)


func _inspect_against_task(stats: Dictionary, task: PCGAssetTask,
		errors: Array[String], warnings: Array[String], issues: Array[Dictionary]) -> void:
	var size: Vector3 = stats.aabb_size
	if task.tri_budget > 0 and stats.triangles > task.tri_budget:
		_add_issue(issues, errors, "error", "tri_budget_exceeded",
			"%d triangles exceed task budget %d" % [stats.triangles, task.tri_budget])
	elif task.tri_budget > 0 and stats.triangles * 10 >= task.tri_budget * 9:
		warnings.append("triangle count %d is within 10%% of budget %d" % [stats.triangles, task.tri_budget])
	var material_count: int = stats.surfaces
	if task.material_budget > 0 and material_count > task.material_budget:
		_add_issue(issues, errors, "error", "material_budget_exceeded",
			"%d material slots exceed task budget %d" % [material_count, task.material_budget])
	for axis in 3:
		var axis_name: String = ["x", "y", "z"][axis]
		var max_limit: float = task.size_max[axis]
		if max_limit > 0.0 and size[axis] > max_limit + SIZE_TOLERANCE:
			_add_issue(issues, errors, "error", "size_over_max",
				"aabb %s extent %.4f exceeds size_max %.4f" % [axis_name, size[axis], max_limit])
		if task.size_min[axis] > 0.0 and size[axis] < task.size_min[axis] - SIZE_TOLERANCE:
			_add_issue(issues, errors, "error", "size_under_min",
				"aabb %s extent %.4f is under size_min %.4f" % [axis_name, size[axis], task.size_min[axis]])


# ------------------------------------------------------------------ 校准

func calibrate_mesh(mesh: Mesh, target_size: Vector3, root_offset: Vector3,
		basis: Basis = Basis.IDENTITY, weld_tolerance: float = 0.00001) -> Dictionary:
	var actions: Array[String] = []
	var errors: Array[String] = []
	if mesh == null or mesh.get_surface_count() == 0:
		errors.append("mesh is null or has no surfaces")
		return {"ok": false, "mesh": null, "errors": errors, "actions": actions, "stats": {}}
	if weld_tolerance <= 0.0:
		errors.append("weld_tolerance must be > 0")
		return {"ok": false, "mesh": null, "errors": errors, "actions": actions, "stats": {}}
	var inspection := inspect_mesh(mesh)
	for issue in inspection["issues"]:
		if String(issue.get("code", "")) == "nan_vertices":
			errors.append("refusing to calibrate: mesh contains NaN vertices; not auto-repaired")
			return {"ok": false, "mesh": null, "errors": errors, "actions": actions, "stats": inspection["stats"]}
	var input_stats: Dictionary = inspection["stats"]
	if int(input_stats["non_manifold_edges"]) > 0:
		errors.append("refusing to calibrate: mesh has %d non-manifold edges; not auto-repaired"
			% int(input_stats["non_manifold_edges"]))
		return {"ok": false, "mesh": null, "errors": errors, "actions": actions, "stats": input_stats}
	if int(input_stats["edges"]) > 0 \
			and float(input_stats["boundary_edges"]) / float(input_stats["edges"]) > OPEN_BOUNDARY_REFUSAL_FRACTION:
		errors.append("refusing to calibrate: %.0f%% of edges are boundary (severely open); not auto-repaired"
			% [float(input_stats["boundary_edges"]) / float(input_stats["edges"]) * 100.0])
		return {"ok": false, "mesh": null, "errors": errors, "actions": actions, "stats": input_stats}
	var preserved_open_boundary := false
	if int(input_stats["boundary_edges"]) > 0:
		preserved_open_boundary = true
		actions.append("open_boundary_preserved:%d" % int(input_stats["boundary_edges"]))

	# 统一缩放：在所有受约束轴上取 target/current 的最小比值，保证不越界。
	var current_size: Vector3 = input_stats["aabb_size"]
	var uniform := INF
	var constrained := false
	for axis in 3:
		if target_size[axis] > 0.0:
			if current_size[axis] <= 0.0:
				errors.append("cannot normalize: aabb extent on axis %d is zero but target is %.4f" % [axis, target_size[axis]])
				return {"ok": false, "mesh": null, "errors": errors, "actions": actions, "stats": input_stats}
			uniform = minf(uniform, target_size[axis] / current_size[axis])
			constrained = true
	if not constrained:
		uniform = 1.0
	if constrained and not is_equal_approx(uniform, 1.0):
		actions.append("scaled_uniform:%.6f" % uniform)

	var transform := basis
	if not is_equal_approx(uniform, 1.0):
		transform = transform.scaled(Vector3.ONE * uniform)
	actions.append("transformed:basis+root_offset")

	# 跨表面共享焊接表：同一空间位置的顶点（容差内）合并为一个规范顶点。
	var weld_map := {}
	var weld_points := PackedVector3Array()
	var surface_remaps: Array[PackedInt32Array] = []
	var surface_keep_tris: Array[PackedInt32Array] = []
	var total_removed := 0
	for surface_index in mesh.get_surface_count():
		var arrays := mesh.surface_get_arrays(surface_index)
		var vertices: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
		var indices := PackedInt32Array()
		if arrays[Mesh.ARRAY_INDEX] != null:
			indices = arrays[Mesh.ARRAY_INDEX]
		if indices.is_empty():
			indices = _sequential_indices(vertices.size())
		var remap := PackedInt32Array()
		remap.resize(vertices.size())
		for vertex_index in vertices.size():
			remap[vertex_index] = _weld_vertex(weld_points, weld_map,
				transform * vertices[vertex_index] + root_offset, weld_tolerance)
		surface_remaps.append(remap)
		var keep := PackedInt32Array()
		for tri in range(indices.size() / 3):
			var a: int = remap[indices[tri * 3]]
			var b: int = remap[indices[tri * 3 + 1]]
			var c: int = remap[indices[tri * 3 + 2]]
			if a == b or b == c or c == a:
				total_removed += 1
				continue
			var area_sq := _triangle_area_squared(weld_points[a], weld_points[b], weld_points[c])
			if area_sq < AREA_EPSILON:
				total_removed += 1
				continue
			keep.append_array([a, b, c])
		surface_keep_tris.append(keep)

	var welded := 0
	for surface_index in mesh.get_surface_count():
		welded += mesh.surface_get_arrays(surface_index)[Mesh.ARRAY_VERTEX].size()
	welded -= weld_points.size()
	if welded > 0:
		actions.append("welded:%d" % welded)
	if total_removed > 0:
		actions.append("removed_degenerate:%d" % total_removed)

	var output := ArrayMesh.new()
	var total_tris := 0
	for surface_index in mesh.get_surface_count():
		var source_arrays := mesh.surface_get_arrays(surface_index)
		var keep: PackedInt32Array = surface_keep_tris[surface_index]
		total_tris += int(keep.size() / 3)
		if keep.is_empty():
			continue
		var out_arrays := []
		out_arrays.resize(Mesh.ARRAY_MAX)
		out_arrays[Mesh.ARRAY_VERTEX] = weld_points
		out_arrays[Mesh.ARRAY_INDEX] = keep
		if source_arrays[Mesh.ARRAY_TEX_UV] != null:
			out_arrays[Mesh.ARRAY_TEX_UV] = _remap_packed(
				source_arrays[Mesh.ARRAY_TEX_UV], surface_remaps[surface_index], weld_points.size())
		if source_arrays[Mesh.ARRAY_NORMAL] != null:
			out_arrays[Mesh.ARRAY_NORMAL] = _remap_packed(
				source_arrays[Mesh.ARRAY_NORMAL], surface_remaps[surface_index], weld_points.size())
		else:
			out_arrays[Mesh.ARRAY_NORMAL] = _flat_normals(weld_points, keep)
		output.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, out_arrays)
		output.surface_set_material(output.get_surface_count() - 1,
			mesh.surface_get_material(surface_index))
	if total_tris == 0:
		errors.append("calibration removed every triangle; nothing left to emit")
		return {"ok": false, "mesh": null, "errors": errors, "actions": actions, "stats": input_stats}

	var final_inspection := inspect_mesh(output)
	var final_stats: Dictionary = final_inspection["stats"]
	var final_errors: Array = final_inspection["errors"]
	if preserved_open_boundary:
		# 输入开放的边界如实保留：不视为校准失败，但把对应错误从结果中剔除并留痕。
		var filtered: Array = []
		for final_error in final_errors:
			if not String(final_error).begins_with("mesh is open"):
				filtered.append(final_error)
		final_errors = filtered
	var ok := int(final_stats["non_manifold_edges"]) == 0 \
		and int(final_stats["degenerate_triangles"]) == 0 \
		and final_errors.is_empty()
	return {
		"ok": ok,
		"mesh": output,
		"errors": final_errors,
		"actions": actions,
		"stats": final_stats,
	}


# ------------------------------------------------------------------ 内部工具

func _pack(errors: Array[String], warnings: Array[String],
		issues: Array[Dictionary], stats: Dictionary) -> Dictionary:
	return {
		"ok": errors.is_empty(),
		"errors": errors,
		"warnings": warnings,
		"issues": issues,
		"stats": stats,
	}


func _add_issue(issues: Array[Dictionary], sink: Array[String],
		severity: String, code: String, detail: String,
		surface: int = -1, triangle: int = -1) -> void:
	sink.append(detail)
	issues.append({
		"severity": severity, "code": code, "detail": detail,
		"surface": surface, "triangle": triangle,
	})


func _edge_key(a: String, b: String) -> String:
	# 位置键（非顶点索引）：共点焊接后的边拓扑才是资产真实的开放/流形状态。
	if a < b:
		return a + "|" + b
	return b + "|" + a


func _pos_key(v: Vector3) -> String:
	return "%.5f|%.5f|%.5f" % [v.x, v.y, v.z]


func _sequential_indices(count: int) -> PackedInt32Array:
	var indices := PackedInt32Array()
	indices.resize(count)
	for i in count:
		indices[i] = i
	return indices


func _triangle_area_squared(a: Vector3, b: Vector3, c: Vector3) -> float:
	return (b - a).cross(c - a).length_squared()


func _has_nan(v: Vector3) -> bool:
	return is_nan(v.x) or is_nan(v.y) or is_nan(v.z)


func _weld_vertex(points: PackedVector3Array, cells: Dictionary,
		position: Vector3, tolerance: float) -> int:
	var cx := int(floor(position.x / tolerance))
	var cy := int(floor(position.y / tolerance))
	var cz := int(floor(position.z / tolerance))
	var tol_sq := tolerance * tolerance
	for dx in [-1, 0, 1]:
		for dy in [-1, 0, 1]:
			for dz in [-1, 0, 1]:
				var cell_key := "%d|%d|%d" % [cx + dx, cy + dy, cz + dz]
				if not cells.has(cell_key):
					continue
				for candidate in cells[cell_key]:
					if points[candidate].distance_squared_to(position) <= tol_sq:
						return candidate
	var own_key := "%d|%d|%d" % [cx, cy, cz]
	if not cells.has(own_key):
		cells[own_key] = []
	cells[own_key].append(points.size())
	points.append(position)
	return points.size() - 1


func _remap_packed(array: Variant, remap: PackedInt32Array, canonical_count: int) -> Variant:
	# 输出按规范顶点数重建：源顶点 i 归并到 canonical remap[i]，先到的取值生效。
	var remapped = array.duplicate()
	remapped.resize(canonical_count)
	for i in remap.size():
		remapped[remap[i]] = array[i]
	return remapped


func _flat_normals(vertices: PackedVector3Array, indices: PackedInt32Array) -> PackedVector3Array:
	var normals := PackedVector3Array()
	normals.resize(vertices.size())
	var accum := PackedVector3Array()
	accum.resize(vertices.size())
	for tri in range(indices.size() / 3):
		var a: int = indices[tri * 3]
		var b: int = indices[tri * 3 + 1]
		var c: int = indices[tri * 3 + 2]
		var face := (vertices[b] - vertices[a]).cross(vertices[c] - vertices[a])
		accum[a] += face
		accum[b] += face
		accum[c] += face
	for i in vertices.size():
		normals[i] = accum[i].normalized() if accum[i].length_squared() > NORMAL_EPSILON else Vector3.UP
	return normals
