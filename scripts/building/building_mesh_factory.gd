@tool
class_name PCGBuildingMeshFactory
extends RefCounted

const MeshBuildUtil = preload("res://addons/pcg_shared/mesh_build_util.gd")

static func component(definition) -> ArrayMesh:
	match definition.geometry:
		definition.Geometry.FRAME:
			return _frame(definition.size, definition.frame_width, false)
		definition.Geometry.DOOR:
			return _frame(definition.size, definition.frame_width, true)
		definition.Geometry.PARAPET:
			return MeshBuildUtil.boxes([
				{"size": definition.size, "center": Vector3.ZERO},
				{"size": Vector3(definition.size.x, definition.size.y * 0.16, definition.size.z * 1.35),
					"center": Vector3(0.0, definition.size.y * 0.5, 0.0)},
			])
		definition.Geometry.AWNING:
			return _awning(definition.size)
		definition.Geometry.ROOF_HATCH:
			return MeshBuildUtil.boxes([
				{"size": definition.size, "center": Vector3.ZERO},
				{"size": Vector3(definition.size.x * 1.08, definition.size.y * 0.14, definition.size.z * 1.08),
					"center": Vector3(0.0, definition.size.y * 0.54, 0.0)},
			])
		definition.Geometry.ROOF_DRYING_RACK:
			return _roof_drying_rack(definition.size)
		definition.Geometry.WINDOW_DRYING_ROD:
			return _window_drying(definition.size, false)
		definition.Geometry.WINDOW_DRYING_CLOTHES:
			return _window_drying(definition.size, true)
		definition.Geometry.BALCONY:
			return _balcony(definition.size)
		definition.Geometry.DOUBLE_DOOR:
			return _double_door(definition.size, definition.frame_width)
		definition.Geometry.SKYBRIDGE:
			var groups := skybridge_part_groups(definition)
			var mesh := MeshBuildUtil.boxes(groups["frame"] + groups["roof"])
			var accent := MeshBuildUtil.boxes(groups["accent"])
			mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, accent.surface_get_arrays(0))
			return mesh
		_:
			return MeshBuildUtil.boxes([{"size": definition.size, "center": Vector3.ZERO}])

# 廊桥横截面单元：薄桥面、两侧边扶手横档与出挑顶棚；支撑顶棚的立柱与栏杆立柱沿桥长按间距独立生成（镂空侧面）。
# 局部 X 为桥宽、Y 以桥面（楼层地面）为 0 向上、Z 为 1 米切片厚度；
# skybridge_generator 沿路径扫掠 frame/accent/roof，并按 post/baluster 的 spacing 等距放置立柱。
# 替换组件契约：frame=桥面等连续结构件，accent=两侧扶手（只允许边缘细件），roof=顶棚，
# post/baluster=等距生成的立柱参数（size/center_y/spacing），相邻件需互相嵌入避免共面。
static func skybridge_part_groups(definition) -> Dictionary:
	var w: float = definition.size.x
	var h: float = definition.size.y
	var deck_t := 0.08
	var rail_h := clampf(h * 0.35, 0.8, 1.2)
	var roof_t := 0.1
	var post_h := maxf(h - roof_t, rail_h + 0.2)
	var edge := w * 0.5 - 0.045
	return {
		"frame": [
			{"size": Vector3(w, deck_t, 1.0), "center": Vector3(0.0, -deck_t * 0.5 + 0.001, 0.0)},
		],
		"accent": [
			{"size": Vector3(0.09, 0.07, 1.0), "center": Vector3(-edge, rail_h, 0.0)},
			{"size": Vector3(0.09, 0.07, 1.0), "center": Vector3(edge, rail_h, 0.0)},
			{"size": Vector3(0.07, 0.16, 1.0), "center": Vector3(-(w * 0.5 - 0.035), 0.1, 0.0)},
			{"size": Vector3(0.07, 0.16, 1.0), "center": Vector3(w * 0.5 - 0.035, 0.1, 0.0)},
		],
		"roof": [
			{"size": Vector3(w * 1.12, roof_t, 1.0),
				"center": Vector3(0.0, post_h - roof_t * 0.5 + 0.02, 0.0)},
		],
		"post": {
			"size": Vector3(0.09, post_h - 0.04, 0.09),
			"center_y": (post_h - 0.04) * 0.5 - 0.01,
			"spacing": 1.6,
		},
		"baluster": {
			"size": Vector3(0.05, rail_h - 0.05, 0.05),
			"center_y": (rail_h - 0.05) * 0.5,
			"spacing": 0.8,
			"x": w * 0.5 - 0.045,
		},
		"portal": {
			"frame_width": 0.12,
			"protrude": 0.14,
		},
	}

static func extrude(polygon: PackedVector2Array, height: float, openings: Array = []) -> ArrayMesh:
	var vertices := PackedVector3Array()
	var normals := PackedVector3Array()
	var uvs := PackedVector2Array()
	var indices := PackedInt32Array()
	var by_edge: Dictionary = {}
	var global_y_cuts: Array[float] = [0.0, height]
	for opening in openings:
		var edge_index: int = int(opening.get("edge_index", -1))
		if edge_index < 0 or edge_index >= polygon.size():
			continue
		if not by_edge.has(edge_index):
			by_edge[edge_index] = []
		by_edge[edge_index].append(opening)
		global_y_cuts.append(clampf(float(opening.get("y0", 0.0)), 0.0, height))
		global_y_cuts.append(clampf(float(opening.get("y1", 0.0)), 0.0, height))
	global_y_cuts = _unique_sorted(global_y_cuts)
	for index in polygon.size():
		var next := (index + 1) % polygon.size()
		var a := polygon[index]
		var b := polygon[next]
		var edge := b - a
		var length := edge.length()
		if length <= 0.0001:
			continue
		var outward := Vector3(edge.y, 0.0, -edge.x).normalized()
		if by_edge.has(index):
			_add_opening_wall(vertices, normals, uvs, indices,
				a, b, length, outward, height, by_edge[index], global_y_cuts)
		else:
			_add_opening_wall(vertices, normals, uvs, indices,
				a, b, length, outward, height, [], global_y_cuts)
	var triangles: PackedInt32Array
	var cap_polygon := polygon
	if openings.is_empty():
		triangles = Geometry2D.triangulate_polygon(polygon)
	else:
		# 屋面/地面三角化使用带切口点的增广轮廓，使顶底棱边与墙面条带分段一致。
		var augmented := PackedVector2Array()
		for index in polygon.size():
			augmented.append(polygon[index])
			if by_edge.has(index):
				var a2: Vector2 = polygon[index]
				var b2: Vector2 = polygon[(index + 1) % polygon.size()]
				var edge_length := a2.distance_to(b2)
				if edge_length > 0.0001:
					var s_cuts: Array[float] = []
					for o in by_edge[index]:
						s_cuts.append(clampf(float(o["s0"]), 0.0, edge_length))
						s_cuts.append(clampf(float(o["s1"]), 0.0, edge_length))
					s_cuts = _unique_sorted(s_cuts)
					for s in s_cuts:
						if s > 0.001 and s < edge_length - 0.001:
							augmented.append(a2 + (b2 - a2) * (s / edge_length))
		cap_polygon = augmented
		triangles = Geometry2D.triangulate_polygon(augmented)
	for index in range(0, triangles.size(), 3):
		var a := cap_polygon[triangles[index]]
		var b := cap_polygon[triangles[index + 1]]
		var c := cap_polygon[triangles[index + 2]]
		MeshBuildUtil.add_face(vertices, normals, uvs, indices, PackedVector3Array([
			Vector3(a.x, height, a.y), Vector3(b.x, height, b.y), Vector3(c.x, height, c.y),
		]), Vector3.UP, PackedVector2Array([a, b, c]))
		MeshBuildUtil.add_face(vertices, normals, uvs, indices, PackedVector3Array([
			Vector3(c.x, 0.0, c.y), Vector3(b.x, 0.0, b.y), Vector3(a.x, 0.0, a.y),
		]), Vector3.DOWN, PackedVector2Array([c, b, a]))
	return MeshBuildUtil.mesh(vertices, normals, uvs, indices)

# 带门洞的立面：按全局高度带切水平条带（全宽，保证与相邻墙面/屋顶/地面的棱边完全对齐），
# 洞口所在带内按 s 区间挖空，并为每个洞口生成五面内凹洞道（地面/顶/两侧/背板），保持封闭流形。
# opening 字段：edge_index、s0/s1（沿边米制区间）、y0/y1（高度区间）、depth（内凹深度）。
static func _add_opening_wall(vertices: PackedVector3Array, normals: PackedVector3Array,
			uvs: PackedVector2Array, indices: PackedInt32Array,
			a: Vector2, b: Vector2, length: float, outward: Vector3, height: float,
			openings: Array, global_y_cuts: Array[float]) -> void:
	var base := Vector3(a.x, 0.0, a.y)
	var dir := Vector3((b.x - a.x) / length, 0.0, (b.y - a.y) / length)
	var sorted: Array = openings.duplicate()
	sorted.sort_custom(func(x, y): return float(x["s0"]) < float(y["s0"]))
	# 该边所有洞口的 s 切点对全部高度带生效，保证相邻带的水平接缝棱边逐段对齐。
	var cuts: Array[float] = [0.0, length]
	for opening in sorted:
		cuts.append(clampf(float(opening["s0"]), 0.0, length))
		cuts.append(clampf(float(opening["s1"]), 0.0, length))
	cuts = _unique_sorted(cuts)
	for row in global_y_cuts.size() - 1:
		var ya: float = global_y_cuts[row]
		var yb: float = global_y_cuts[row + 1]
		if yb - ya <= 0.000001:
			continue
		for column in cuts.size() - 1:
			var ca: float = cuts[column]
			var cb: float = cuts[column + 1]
			if cb - ca <= 0.000001:
				continue
			var mid_s := (ca + cb) * 0.5
			var mid_y := (ya + yb) * 0.5
			var hole := false
			for opening in sorted:
				if float(opening["s0"]) <= mid_s and float(opening["s1"]) >= mid_s \
						and float(opening["y0"]) <= mid_y and float(opening["y1"]) >= mid_y:
					hole = true
					break
			if not hole:
				_emit_wall_quad(vertices, normals, uvs, indices,
					base, dir, outward, ca, cb, ya, yb)
	for opening in sorted:
		_add_tunnel(vertices, normals, uvs, indices,
			base, dir, outward,
			clampf(float(opening["s0"]), 0.0, length),
			clampf(float(opening["s1"]), 0.0, length),
			clampf(float(opening["y0"]), 0.0, height),
			clampf(float(opening["y1"]), 0.0, height),
			float(opening.get("depth", 0.45)))

static func _emit_wall_quad(vertices: PackedVector3Array, normals: PackedVector3Array,
			uvs: PackedVector2Array, indices: PackedInt32Array,
			base: Vector3, dir: Vector3, outward: Vector3,
			s0: float, s1: float, y0: float, y1: float) -> void:
	MeshBuildUtil.add_face(vertices, normals, uvs, indices, PackedVector3Array([
		_wall_point(base, dir, s0, y0), _wall_point(base, dir, s1, y0),
		_wall_point(base, dir, s1, y1), _wall_point(base, dir, s0, y1),
	]), outward, PackedVector2Array([
		Vector2(s0, y0), Vector2(s1, y0), Vector2(s1, y1), Vector2(s0, y1)]))

static func _wall_point(base: Vector3, dir: Vector3, s: float, y: float) -> Vector3:
	return base + dir * s + Vector3.UP * y

# 生成内凹洞道的五个内表面（地面、顶、左右侧、背板），与墙面条带共享棱边，保持封闭。
static func _add_tunnel(vertices: PackedVector3Array, normals: PackedVector3Array,
			uvs: PackedVector2Array, indices: PackedInt32Array,
			base: Vector3, dir: Vector3, outward: Vector3,
			s0: float, s1: float, y0: float, y1: float, depth: float) -> void:
	var f0 := _wall_point(base, dir, s0, y0)
	var f1 := _wall_point(base, dir, s1, y0)
	var f2 := _wall_point(base, dir, s1, y1)
	var f3 := _wall_point(base, dir, s0, y1)
	var b0 := f0 - outward * depth
	var b1 := f1 - outward * depth
	var b2 := f2 - outward * depth
	var b3 := f3 - outward * depth
	MeshBuildUtil.add_face(vertices, normals, uvs, indices,
		PackedVector3Array([f0, f1, b1, b0]), Vector3.UP,
		PackedVector2Array([Vector2(s0, 0), Vector2(s1, 0), Vector2(s1, depth), Vector2(s0, depth)]))
	MeshBuildUtil.add_face(vertices, normals, uvs, indices,
		PackedVector3Array([f3, b3, b2, f2]), Vector3.DOWN,
		PackedVector2Array([Vector2(s0, 0), Vector2(s0, depth), Vector2(s1, depth), Vector2(s1, 0)]))
	MeshBuildUtil.add_face(vertices, normals, uvs, indices,
		PackedVector3Array([f0, b0, b3, f3]), dir,
		PackedVector2Array([Vector2(0, y0), Vector2(depth, y0), Vector2(depth, y1), Vector2(0, y1)]))
	MeshBuildUtil.add_face(vertices, normals, uvs, indices,
		PackedVector3Array([f1, f2, b2, b1]), -dir,
		PackedVector2Array([Vector2(0, y0), Vector2(0, y1), Vector2(depth, y1), Vector2(depth, y0)]))
	MeshBuildUtil.add_face(vertices, normals, uvs, indices,
		PackedVector3Array([b0, b1, b2, b3]), outward,
		PackedVector2Array([Vector2(s0, y0), Vector2(s1, y0), Vector2(s1, y1), Vector2(s0, y1)]))

static func _unique_sorted(values: Array[float]) -> Array[float]:
	var ordered: Array[float] = values.duplicate()
	ordered.sort()
	var result: Array[float] = []
	for value in ordered:
		if result.is_empty() or value > result[-1] + 0.000001:
			result.append(value)
	return result

static func _frame(size: Vector3, width: float, door: bool) -> ArrayMesh:
	var mesh := _rect_ring(size, width)
	if not door:
		var mullion := MeshBuildUtil.boxes([{
			"size": Vector3(width * 0.45, size.y, size.z * 0.65),
			"center": Vector3(0.0, 0.0, size.z * 0.5),
		}])
		var surface := SurfaceTool.new()
		surface.begin(Mesh.PRIMITIVE_TRIANGLES)
		surface.append_from(mesh, 0, Transform3D.IDENTITY)
		surface.append_from(mullion, 0, Transform3D.IDENTITY)
		mesh = surface.commit()
	var panel := MeshBuildUtil.boxes([{
		"size": Vector3(size.x - width * 2.0, size.y - width * 2.0, size.z * 0.18),
		"center": Vector3(0.0, 0.0, size.z * 0.12),
	}])
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, panel.surface_get_arrays(0))
	return mesh

static func _rect_ring(size: Vector3, width: float) -> ArrayMesh:
	var half := size * 0.5
	var outer := PackedVector2Array([
		Vector2(-half.x, -half.y), Vector2(half.x, -half.y),
		Vector2(half.x, half.y), Vector2(-half.x, half.y),
	])
	var inner := PackedVector2Array([
		Vector2(-half.x + width, -half.y + width), Vector2(half.x - width, -half.y + width),
		Vector2(half.x - width, half.y - width), Vector2(-half.x + width, half.y - width),
	])
	var vertices := PackedVector3Array()
	var normals := PackedVector3Array()
	var uvs := PackedVector2Array()
	var indices := PackedInt32Array()
	for index in 4:
		var next := (index + 1) % 4
		var oa := outer[index]
		var ob := outer[next]
		var ia := inner[index]
		var ib := inner[next]
		var edge := ob - oa
		var outward := Vector3(edge.y, -edge.x, 0.0).normalized()
		_ring_face(vertices, normals, uvs, indices, PackedVector3Array([
			Vector3(oa.x, oa.y, 0.0), Vector3(oa.x, oa.y, size.z),
			Vector3(ob.x, ob.y, size.z), Vector3(ob.x, ob.y, 0.0),
		]), outward)
		_ring_face(vertices, normals, uvs, indices, PackedVector3Array([
			Vector3(ia.x, ia.y, 0.0), Vector3(ib.x, ib.y, 0.0),
			Vector3(ib.x, ib.y, size.z), Vector3(ia.x, ia.y, size.z),
		]), -outward)
		_ring_face(vertices, normals, uvs, indices, PackedVector3Array([
			Vector3(oa.x, oa.y, size.z), Vector3(ia.x, ia.y, size.z),
			Vector3(ib.x, ib.y, size.z), Vector3(ob.x, ob.y, size.z),
		]), Vector3.BACK)
		_ring_face(vertices, normals, uvs, indices, PackedVector3Array([
			Vector3(oa.x, oa.y, 0.0), Vector3(ob.x, ob.y, 0.0),
			Vector3(ib.x, ib.y, 0.0), Vector3(ia.x, ia.y, 0.0),
		]), Vector3.FORWARD)
	return MeshBuildUtil.mesh(vertices, normals, uvs, indices)

static func _ring_face(vertices: PackedVector3Array, normals: PackedVector3Array,
			uvs: PackedVector2Array, indices: PackedInt32Array,
			points: PackedVector3Array, normal: Vector3) -> void:
	var face_uvs := PackedVector2Array()
	for point in points:
		if absf(normal.z) > 0.5:
			face_uvs.append(Vector2(point.x, point.y))
		elif absf(normal.x) > 0.5:
			face_uvs.append(Vector2(point.z, point.y))
		else:
			face_uvs.append(Vector2(point.x, point.z))
	MeshBuildUtil.add_face(vertices, normals, uvs, indices, points, normal, face_uvs)

static func _roof_drying_rack(size: Vector3) -> ArrayMesh:
	var parts: Array = []
	for x in [-0.36, 0.36]:
		parts.append({"size": Vector3(0.055, size.y, 0.055), "center": Vector3(size.x * x, 0.0, 0.0)})
		parts.append({"size": Vector3(0.2, 0.055, size.z), "center": Vector3(size.x * x, -size.y * 0.48, 0.0)})
	for z in [-0.32, 0.32]:
		parts.append({"size": Vector3(size.x * 0.88, 0.05, 0.05), "center": Vector3(0.0, size.y * 0.45, size.z * z)})
	return MeshBuildUtil.boxes(parts)

static func _window_drying(size: Vector3, clothes: bool) -> ArrayMesh:
	var rod_y := size.y * 0.32 if clothes else 0.0
	var parts: Array = []
	for x in [-0.38, 0.38]:
		parts.append({"size": Vector3(0.05, 0.05, size.z * 0.94), "center": Vector3(size.x * x, rod_y - 0.04, size.z * 0.47)})
	for z in [0.58, 0.88]:
		parts.append({"size": Vector3(size.x * 0.92, 0.045, 0.045), "center": Vector3(0.0, rod_y, size.z * z)})
	var mesh := MeshBuildUtil.boxes(parts)
	if clothes:
		var panels: Array = []
		for x in [-0.32, 0.0, 0.32]:
			panels.append({"size": Vector3(0.26, size.y * 0.72, 0.025),
				"center": Vector3(x, rod_y - size.y * 0.32, size.z * 0.88)})
		var cloth := MeshBuildUtil.boxes(panels)
		mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, cloth.surface_get_arrays(0))
	return mesh

static func _awning(size: Vector3) -> ArrayMesh:
	var parts: Array = [{
		"size": size, "center": Vector3(0.0, 0.0, size.z * 0.5),
		"basis": Basis(Vector3.RIGHT, deg_to_rad(-12.0)),
	}]
	for x in [-size.x * 0.42, size.x * 0.42]:
		parts.append(_beam_between(
			Vector3(x, -0.55, -0.04),
			Vector3(x, -0.05, size.z * 0.85), 0.045))
	return MeshBuildUtil.boxes(parts)

static func _balcony(size: Vector3) -> ArrayMesh:
	var parts: Array = [
		{"size": Vector3(size.x, size.y * 0.12, size.z), "center": Vector3(0.0, -size.y * 0.4, size.z * 0.5)},
		{"size": Vector3(size.x, 0.06, 0.06), "center": Vector3(0.0, size.y * 0.4, size.z * 0.96)},
	]
	for x in [-0.47, -0.24, 0.0, 0.24, 0.47]:
		parts.append({"size": Vector3(0.035, size.y * 0.82, 0.035),
			"center": Vector3(size.x * x, 0.0, size.z * 0.96)})
	for x in [-0.47, 0.47]:
		parts.append({"size": Vector3(0.05, 0.05, size.z * 0.94),
			"center": Vector3(size.x * x, size.y * 0.4, size.z * 0.49)})
	var mesh := MeshBuildUtil.boxes(parts)
	var plants: Array = []
	for x in [-0.32, 0.0, 0.32]:
		plants.append({"size": Vector3(0.14, 0.16, 0.14), "center": Vector3(x, -0.04, size.z * 0.58)})
		plants.append({"size": Vector3(0.22, 0.18, 0.18), "center": Vector3(x, 0.13, size.z * 0.58)})
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, MeshBuildUtil.boxes(plants).surface_get_arrays(0))
	return mesh

static func _beam_between(start: Vector3, end: Vector3, thickness: float) -> Dictionary:
	var delta := end - start
	return {
		"size": Vector3(thickness, delta.length(), thickness),
		"center": (start + end) * 0.5,
		"basis": Basis(Quaternion(Vector3.UP, delta.normalized())),
	}

static func _double_door(size: Vector3, width: float) -> ArrayMesh:
	var frame := _rect_ring(Vector3(size.x * 0.9, size.y * 0.82, 0.14), width)
	var canopy_parts: Array = [
		{"size": Vector3(size.x, 0.1, size.z), "center": Vector3(0.0, size.y * 0.43, size.z * 0.5)},
	]
	for x in [-size.x * 0.38, size.x * 0.38]:
		canopy_parts.append(_beam_between(
			Vector3(x, size.y * 0.16, -0.04),
			Vector3(x, size.y * 0.38, size.z * 0.85), 0.065))
	var canopy := MeshBuildUtil.boxes(canopy_parts)
	var surface := SurfaceTool.new()
	surface.begin(Mesh.PRIMITIVE_TRIANGLES)
	surface.append_from(frame, 0, Transform3D(Basis.IDENTITY, Vector3(0.0, -size.y * 0.08, 0.0)))
	surface.append_from(canopy, 0, Transform3D.IDENTITY)
	var mesh := surface.commit()
	var panel_width := (size.x * 0.9 - width * 2.0 - 0.04) * 0.5
	var panels := MeshBuildUtil.boxes([
		{"size": Vector3(panel_width, size.y * 0.68, 0.04),
			"center": Vector3(-panel_width * 0.5 - 0.02, -size.y * 0.1, 0.04)},
		{"size": Vector3(panel_width, size.y * 0.68, 0.04),
			"center": Vector3(panel_width * 0.5 + 0.02, -size.y * 0.1, 0.04)},
	])
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, panels.surface_get_arrays(0))
	return mesh

static func foundation(polygon: PackedVector2Array, terrain: PCGBuildingPlan, base: float) -> ArrayMesh:
	var vertices := PackedVector3Array()
	var normals := PackedVector3Array()
	var uvs := PackedVector2Array()
	var indices := PackedInt32Array()
	for index in polygon.size():
		var next := (index + 1) % polygon.size()
		var a := polygon[index]
		var b := polygon[next]
		var edge := b - a
		var outward := Vector3(edge.y, 0.0, -edge.x).normalized()
		var p0 := Vector3(a.x, terrain.terrain_height_at(a) - base - 0.08, a.y)
		var p1 := Vector3(b.x, terrain.terrain_height_at(b) - base - 0.08, b.y)
		var p2 := Vector3(b.x, 0.0, b.y)
		var p3 := Vector3(a.x, 0.0, a.y)
		MeshBuildUtil.add_face(vertices, normals, uvs, indices, PackedVector3Array([p0, p1, p2, p3]), outward,
			PackedVector2Array([Vector2.ZERO, Vector2(edge.length(), 0.0), Vector2(edge.length(), p2.y), Vector2(0.0, p3.y)]))
	var triangles := Geometry2D.triangulate_polygon(polygon)
	for index in range(0, triangles.size(), 3):
		var a := polygon[triangles[index]]
		var b := polygon[triangles[index + 1]]
		var c := polygon[triangles[index + 2]]
		MeshBuildUtil.add_face(vertices, normals, uvs, indices, PackedVector3Array([
			Vector3(a.x, 0.0, a.y), Vector3(b.x, 0.0, b.y), Vector3(c.x, 0.0, c.y),
		]), Vector3.UP, PackedVector2Array([a, b, c]))
		MeshBuildUtil.add_face(vertices, normals, uvs, indices, PackedVector3Array([
			Vector3(c.x, terrain.terrain_height_at(c) - base - 0.08, c.y),
			Vector3(b.x, terrain.terrain_height_at(b) - base - 0.08, b.y),
			Vector3(a.x, terrain.terrain_height_at(a) - base - 0.08, a.y),
		]), Vector3.DOWN, PackedVector2Array([c, b, a]))
	return MeshBuildUtil.mesh(vertices, normals, uvs, indices)
