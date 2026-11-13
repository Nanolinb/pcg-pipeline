@tool
class_name PCGBuildingMeshFactory
extends RefCounted

static func component(definition) -> ArrayMesh:
	match definition.geometry:
		definition.Geometry.FRAME:
			return _frame(definition.size, definition.frame_width, false)
		definition.Geometry.DOOR:
			return _frame(definition.size, definition.frame_width, true)
		definition.Geometry.PARAPET:
			return _boxes([
				{"size": definition.size, "center": Vector3.ZERO},
				{"size": Vector3(definition.size.x, definition.size.y * 0.16, definition.size.z * 1.35),
					"center": Vector3(0.0, definition.size.y * 0.5, 0.0)},
			])
		definition.Geometry.AWNING:
			return _boxes([
				{"size": Vector3(definition.size.x, definition.size.y, definition.size.z),
					"center": Vector3(0.0, 0.0, definition.size.z * 0.5),
					"basis": Basis(Vector3.RIGHT, deg_to_rad(-12.0))},
				{"size": Vector3(definition.size.x * 0.035, definition.size.y, definition.size.z),
					"center": Vector3(-definition.size.x * 0.42, -definition.size.y * 1.8, definition.size.z * 0.48),
					"basis": Basis(Vector3.RIGHT, deg_to_rad(32.0))},
				{"size": Vector3(definition.size.x * 0.035, definition.size.y, definition.size.z),
					"center": Vector3(definition.size.x * 0.42, -definition.size.y * 1.8, definition.size.z * 0.48),
					"basis": Basis(Vector3.RIGHT, deg_to_rad(32.0))},
			])
		definition.Geometry.ROOF_HATCH:
			return _boxes([
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
			var mesh := _boxes(groups["frame"])
			var accent := _boxes(groups["accent"])
			mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, accent.surface_get_arrays(0))
			return mesh
		_:
			return _boxes([{"size": definition.size, "center": Vector3.ZERO}])

# 廊桥横截面单元：桥面、双侧围栏、顶棚立柱与顶棚。
# 局部 X 为桥宽、Y 以桥面为 0 向上、Z 为 1 米切片厚度；
# skybridge_generator 沿路径扫掠这些截面件生成整条廊桥。
static func skybridge_part_groups(definition) -> Dictionary:
	var w: float = definition.size.x
	var h: float = definition.size.y
	var deck_t := 0.12
	var rail_h := clampf(h * 0.35, 0.8, 1.2)
	var roof_t := 0.1
	var post_h := maxf(h - roof_t, rail_h + 0.2)
	return {
		"frame": [
			{"size": Vector3(w, deck_t, 1.0), "center": Vector3(0.0, -deck_t * 0.5 + 0.001, 0.0)},
			{"size": Vector3(0.08, post_h + 0.02, 1.0),
				"center": Vector3(-(w * 0.5 - 0.05), post_h * 0.5 - 0.01, 0.0)},
			{"size": Vector3(0.08, post_h + 0.02, 1.0),
				"center": Vector3(w * 0.5 - 0.05, post_h * 0.5 - 0.01, 0.0)},
			{"size": Vector3(w * 1.12, roof_t, 1.0),
				"center": Vector3(0.0, post_h - roof_t * 0.5 + 0.02, 0.0)},
		],
		"accent": [
			{"size": Vector3(0.05, rail_h, 1.0),
				"center": Vector3(-(w * 0.5 - 0.025), rail_h * 0.5 - 0.005, 0.0)},
			{"size": Vector3(0.05, rail_h, 1.0),
				"center": Vector3(w * 0.5 - 0.025, rail_h * 0.5 - 0.005, 0.0)},
			{"size": Vector3(w, 0.07, 1.0), "center": Vector3(0.0, rail_h, 0.0)},
		],
	}

static func extrude(polygon: PackedVector2Array, height: float) -> ArrayMesh:
	var vertices := PackedVector3Array()
	var normals := PackedVector3Array()
	var uvs := PackedVector2Array()
	var indices := PackedInt32Array()
	for index in polygon.size():
		var next := (index + 1) % polygon.size()
		var a := polygon[index]
		var b := polygon[next]
		var edge := b - a
		var length := edge.length()
		if length <= 0.0001:
			continue
		var outward := Vector3(edge.y, 0.0, -edge.x).normalized()
		var p0 := Vector3(a.x, 0.0, a.y)
		var p1 := Vector3(b.x, 0.0, b.y)
		var p2 := Vector3(b.x, height, b.y)
		var p3 := Vector3(a.x, height, a.y)
		_add_face(vertices, normals, uvs, indices,
			PackedVector3Array([p0, p1, p2, p3]), outward,
			PackedVector2Array([Vector2.ZERO, Vector2(length, 0.0), Vector2(length, height), Vector2(0.0, height)]))
	var triangles := Geometry2D.triangulate_polygon(polygon)
	for index in range(0, triangles.size(), 3):
		var a := polygon[triangles[index]]
		var b := polygon[triangles[index + 1]]
		var c := polygon[triangles[index + 2]]
		_add_face(vertices, normals, uvs, indices, PackedVector3Array([
			Vector3(a.x, height, a.y), Vector3(b.x, height, b.y), Vector3(c.x, height, c.y),
		]), Vector3.UP, PackedVector2Array([a, b, c]))
		_add_face(vertices, normals, uvs, indices, PackedVector3Array([
			Vector3(c.x, 0.0, c.y), Vector3(b.x, 0.0, b.y), Vector3(a.x, 0.0, a.y),
		]), Vector3.DOWN, PackedVector2Array([c, b, a]))
	return _mesh(vertices, normals, uvs, indices)

static func _frame(size: Vector3, width: float, door: bool) -> ArrayMesh:
	var mesh := _rect_ring(size, width)
	if not door:
		var mullion := _boxes([{
			"size": Vector3(width * 0.45, size.y, size.z * 0.65),
			"center": Vector3(0.0, 0.0, size.z * 0.5),
		}])
		var surface := SurfaceTool.new()
		surface.begin(Mesh.PRIMITIVE_TRIANGLES)
		surface.append_from(mesh, 0, Transform3D.IDENTITY)
		surface.append_from(mullion, 0, Transform3D.IDENTITY)
		mesh = surface.commit()
	var panel := _boxes([{
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
	return _mesh(vertices, normals, uvs, indices)

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
	_add_face(vertices, normals, uvs, indices, points, normal, face_uvs)

static func _roof_drying_rack(size: Vector3) -> ArrayMesh:
	var parts: Array = []
	for x in [-0.36, 0.36]:
		parts.append({"size": Vector3(0.055, size.y, 0.055), "center": Vector3(size.x * x, 0.0, 0.0)})
		parts.append({"size": Vector3(0.2, 0.055, size.z), "center": Vector3(size.x * x, -size.y * 0.48, 0.0)})
	for z in [-0.32, 0.32]:
		parts.append({"size": Vector3(size.x * 0.88, 0.05, 0.05), "center": Vector3(0.0, size.y * 0.45, size.z * z)})
	return _boxes(parts)

static func _window_drying(size: Vector3, clothes: bool) -> ArrayMesh:
	var rod_y := size.y * 0.32 if clothes else 0.0
	var parts: Array = []
	for x in [-0.38, 0.38]:
		parts.append({"size": Vector3(0.05, 0.05, size.z * 0.94), "center": Vector3(size.x * x, rod_y - 0.04, size.z * 0.47)})
	for z in [0.58, 0.88]:
		parts.append({"size": Vector3(size.x * 0.92, 0.045, 0.045), "center": Vector3(0.0, rod_y, size.z * z)})
	var mesh := _boxes(parts)
	if clothes:
		var panels: Array = []
		for x in [-0.32, 0.0, 0.32]:
			panels.append({"size": Vector3(0.26, size.y * 0.72, 0.025),
				"center": Vector3(x, rod_y - size.y * 0.32, size.z * 0.88)})
		var cloth := _boxes(panels)
		mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, cloth.surface_get_arrays(0))
	return mesh

static func _balcony(size: Vector3) -> ArrayMesh:
	var parts: Array = [
		{"size": Vector3(size.x, size.y * 0.12, size.z), "center": Vector3(0.0, -size.y * 0.4, size.z * 0.5)},
		{"size": Vector3(size.x, 0.06, 0.06), "center": Vector3(0.0, size.y * 0.4, size.z * 0.96)},
	]
	for x in [-0.47, -0.24, 0.0, 0.24, 0.47]:
		parts.append({"size": Vector3(0.045, size.y * 0.82, 0.045),
			"center": Vector3(size.x * x, 0.0, size.z * 0.96)})
	for x in [-0.47, 0.47]:
		parts.append({"size": Vector3(0.06, 0.06, size.z * 0.94),
			"center": Vector3(size.x * x, size.y * 0.4, size.z * 0.49)})
	return _boxes(parts)

static func _double_door(size: Vector3, width: float) -> ArrayMesh:
	var frame := _rect_ring(Vector3(size.x * 0.9, size.y * 0.82, 0.14), width)
	var canopy := _boxes([
		{"size": Vector3(size.x, 0.1, size.z), "center": Vector3(0.0, size.y * 0.43, size.z * 0.5)},
		{"size": Vector3(0.08, 0.5, size.z * 0.62), "center": Vector3(-size.x * 0.38, size.y * 0.31, size.z * 0.28),
			"basis": Basis(Vector3.RIGHT, deg_to_rad(32.0))},
		{"size": Vector3(0.08, 0.5, size.z * 0.62), "center": Vector3(size.x * 0.38, size.y * 0.31, size.z * 0.28),
			"basis": Basis(Vector3.RIGHT, deg_to_rad(32.0))},
	])
	var surface := SurfaceTool.new()
	surface.begin(Mesh.PRIMITIVE_TRIANGLES)
	surface.append_from(frame, 0, Transform3D(Basis.IDENTITY, Vector3(0.0, -size.y * 0.08, 0.0)))
	surface.append_from(canopy, 0, Transform3D.IDENTITY)
	var mesh := surface.commit()
	var panel_width := (size.x * 0.9 - width * 2.0 - 0.04) * 0.5
	var panels := _boxes([
		{"size": Vector3(panel_width, size.y * 0.68, 0.04),
			"center": Vector3(-panel_width * 0.5 - 0.02, -size.y * 0.1, 0.04)},
		{"size": Vector3(panel_width, size.y * 0.68, 0.04),
			"center": Vector3(panel_width * 0.5 + 0.02, -size.y * 0.1, 0.04)},
	])
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, panels.surface_get_arrays(0))
	return mesh

static func _boxes(parts: Array) -> ArrayMesh:
	var surface := SurfaceTool.new()
	surface.begin(Mesh.PRIMITIVE_TRIANGLES)
	for part in parts:
		var box := BoxMesh.new()
		box.size = part["size"]
		var basis: Basis = part.get("basis", Basis.IDENTITY)
		surface.append_from(box, 0, Transform3D(basis, part["center"]))
	return surface.commit()

static func _mesh(vertices: PackedVector3Array, normals: PackedVector3Array,
			uvs: PackedVector2Array, indices: PackedInt32Array) -> ArrayMesh:
	var arrays: Array = []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = vertices
	arrays[Mesh.ARRAY_NORMAL] = normals
	arrays[Mesh.ARRAY_TEX_UV] = uvs
	arrays[Mesh.ARRAY_INDEX] = indices
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	return mesh

static func _add_face(vertices: PackedVector3Array, normals: PackedVector3Array,
			uvs: PackedVector2Array, indices: PackedInt32Array,
			points: PackedVector3Array, normal: Vector3, face_uvs: PackedVector2Array) -> void:
	for corner in range(1, points.size() - 1):
		for index in [0, corner, corner + 1]:
			indices.append(vertices.size())
			vertices.append(points[index])
			normals.append(normal)
			uvs.append(face_uvs[index])
