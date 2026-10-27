class_name SurfacePathSolver
extends RefCounted

static var _cache: Dictionary = {}

static func find_path(start: Dictionary, finish: Dictionary) -> Dictionary:
	var collider = start.get("collider")
	if collider == null or collider != finish.get("collider"):
		return {"error": "起点和终点必须位于同一个碰撞表面。"}
	var data: Dictionary = _surface_data(collider)
	if data.is_empty():
		return {"error": "该碰撞体没有可用于表面寻路的网格。"}
	var start_id: int = _nearest_face(data["triangles"], start["position"])
	var finish_id: int = _nearest_face(data["triangles"], finish["position"])
	if start_id < 0 or finish_id < 0:
		return {"error": "无法定位起止点所在的三角面。"}
	var astar: AStar3D = data["astar"]
	var ids: PackedInt64Array = astar.get_id_path(start_id, finish_id)
	if ids.is_empty():
		return {"error": "起止点在当前表面上不连通。"}
	var points: Array[Vector3] = [start["position"]]
	var normals: Array[Vector3] = [start["normal"]]
	for id in ids:
		points.append(data["centers"][id])
		normals.append(data["normals"][id])
	points.append(finish["position"])
	normals.append(finish["normal"])
	return {"points": points, "normals": normals, "collider": collider}

static func smooth_and_project(points: Array, normals: Array, collider: CollisionObject3D, iterations: int, space: PhysicsDirectSpaceState3D, hard_corners: Array = [], corner_segments: Array = [], wall_offsets: Array = []) -> Dictionary:
	if corner_segments.size() == points.size():
		return _fillet_and_project(points, normals, collider, space, hard_corners, corner_segments, wall_offsets)
	if hard_corners.size() == points.size():
		var boundaries: Array[int] = [0]
		for i in range(1, points.size() - 1):
			if hard_corners[i]:
				boundaries.append(i)
		boundaries.append(points.size() - 1)
		if boundaries.size() > 2:
			var output_points: Array = []
			var output_normals: Array = []
			for boundary in range(boundaries.size() - 1):
				var first: int = boundaries[boundary]
				var last: int = boundaries[boundary + 1] + 1
				var section: Dictionary = smooth_and_project(points.slice(first, last), normals.slice(first, last), collider, iterations, space)
				for i in section["points"].size():
					if i == 0 and not output_points.is_empty():
						continue
					output_points.append(section["points"][i])
					output_normals.append(section["normals"][i])
			return {"points": output_points, "normals": output_normals}
	var current_points: Array = points.duplicate()
	var current_normals: Array = normals.duplicate()
	for iteration in iterations:
		if current_points.size() < 3:
			break
		var next_points: Array = [current_points[0]]
		var next_normals: Array = [current_normals[0]]
		for i in range(current_points.size() - 1):
			next_points.append(current_points[i].lerp(current_points[i + 1], 0.25))
			next_normals.append(current_normals[i].lerp(current_normals[i + 1], 0.25).normalized())
			next_points.append(current_points[i].lerp(current_points[i + 1], 0.75))
			next_normals.append(current_normals[i].lerp(current_normals[i + 1], 0.75).normalized())
		next_points.append(current_points[-1])
		next_normals.append(current_normals[-1])
		for i in range(1, next_points.size() - 1):
			var projected: Dictionary = project(next_points[i], next_normals[i], collider, space)
			if not projected.is_empty():
				next_points[i] = projected["position"]
				next_normals[i] = projected["normal"]
		current_points = next_points
		current_normals = next_normals
	return {"points": current_points, "normals": current_normals}

static func _fillet_and_project(points: Array, normals: Array, collider: CollisionObject3D, space: PhysicsDirectSpaceState3D, hard_corners: Array, corner_segments: Array, wall_offsets: Array) -> Dictionary:
	var output_points: Array = [points[0]]
	var output_normals: Array = [normals[0]]
	var output_offsets: Array[float] = [wall_offsets[0] if wall_offsets.size() == points.size() else 0.0]
	for i in range(1, points.size() - 1):
		if hard_corners.size() == points.size() and hard_corners[i]:
			output_points.append(points[i])
			output_normals.append(normals[i])
			output_offsets.append(wall_offsets[i] if wall_offsets.size() == points.size() else 0.0)
			continue
		var start: Vector3 = points[i].lerp(points[i - 1], 0.25)
		var finish: Vector3 = points[i].lerp(points[i + 1], 0.25)
		var start_normal: Vector3 = normals[i].lerp(normals[i - 1], 0.25).normalized()
		var finish_normal: Vector3 = normals[i].lerp(normals[i + 1], 0.25).normalized()
		var segment_count: int = clampi(int(corner_segments[i]), 2, 64)
		for step in range(segment_count + 1):
			var t: float = float(step) / float(segment_count)
			var u: float = 1.0 - t
			var point: Vector3 = start * (u * u) + points[i] * (2.0 * u * t) + finish * (t * t)
			var normal: Vector3 = (start_normal * (u * u) + normals[i] * (2.0 * u * t) + finish_normal * (t * t)).normalized()
			var offset: float = 0.0
			if wall_offsets.size() == points.size():
				var start_offset: float = lerpf(wall_offsets[i], wall_offsets[i - 1], 0.25)
				var finish_offset: float = lerpf(wall_offsets[i], wall_offsets[i + 1], 0.25)
				offset = start_offset * (u * u) + wall_offsets[i] * (2.0 * u * t) + finish_offset * (t * t)
			var projected: Dictionary = project(point, normal, collider, space)
			if not projected.is_empty():
				point = projected["position"]
				normal = projected["normal"]
			output_points.append(point)
			output_normals.append(normal)
			output_offsets.append(offset)
	output_points.append(points[-1])
	output_normals.append(normals[-1])
	output_offsets.append(wall_offsets[-1] if wall_offsets.size() == points.size() else 0.0)
	return {"points": output_points, "normals": output_normals, "wall_offsets": output_offsets}

static func project(point: Vector3, normal: Vector3, collider: CollisionObject3D, space: PhysicsDirectSpaceState3D) -> Dictionary:
	var direction: Vector3 = normal.normalized()
	var query := PhysicsRayQueryParameters3D.create(point + direction * 1.5, point - direction * 2.5)
	query.hit_from_inside = true
	var hit: Dictionary = space.intersect_ray(query)
	if hit.is_empty() or hit.get("collider") != collider:
		return {}
	if hit["normal"].dot(direction) < 0.0:
		hit["normal"] = -hit["normal"]
	return hit

static func _surface_data(collider: CollisionObject3D) -> Dictionary:
	var key: int = collider.get_instance_id()
	if _cache.has(key):
		return _cache[key]
	var mesh_instance: MeshInstance3D = _find_mesh(collider)
	if mesh_instance == null or mesh_instance.mesh == null:
		return {}
	var triangles: Array = []
	var centers: Array[Vector3] = []
	var normals: Array[Vector3] = []
	var edge_faces: Dictionary = {}
	var astar := AStar3D.new()
	for surface in mesh_instance.mesh.get_surface_count():
		var arrays: Array = mesh_instance.mesh.surface_get_arrays(surface)
		var vertices: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
		var vertex_normals = arrays[Mesh.ARRAY_NORMAL]
		var normal_transform: Basis = mesh_instance.global_transform.basis.inverse().transposed()
		var face_indices: PackedInt32Array = arrays[Mesh.ARRAY_INDEX]
		if face_indices.is_empty():
			for i in vertices.size():
				face_indices.append(i)
		for offset in range(0, face_indices.size() - 2, 3):
			var ia: int = face_indices[offset]
			var ib: int = face_indices[offset + 1]
			var ic: int = face_indices[offset + 2]
			var a: Vector3 = mesh_instance.global_transform * vertices[ia]
			var b: Vector3 = mesh_instance.global_transform * vertices[ib]
			var c: Vector3 = mesh_instance.global_transform * vertices[ic]
			var normal: Vector3 = (b - a).cross(c - a)
			if normal.length_squared() < 0.00000001:
				continue
			if vertex_normals != null and vertex_normals.size() > maxi(ia, maxi(ib, ic)):
				normal = normal_transform * (vertex_normals[ia] + vertex_normals[ib] + vertex_normals[ic])
			var id: int = centers.size()
			normal = normal.normalized()
			triangles.append([a, b, c])
			centers.append((a + b + c) / 3.0)
			normals.append(normal)
			astar.add_point(id, centers[id])
			var keys: Array[String] = [_vertex_key(a), _vertex_key(b), _vertex_key(c)]
			for edge in 3:
				var first: String = keys[edge]
				var second: String = keys[(edge + 1) % 3]
				var edge_key: String = first + "|" + second if first < second else second + "|" + first
				if not edge_faces.has(edge_key):
					edge_faces[edge_key] = []
				edge_faces[edge_key].append(id)
	for faces in edge_faces.values():
		for i in faces.size():
			for j in range(i + 1, faces.size()):
				astar.connect_points(faces[i], faces[j])
	var result: Dictionary = {"triangles": triangles, "centers": centers, "normals": normals, "astar": astar}
	_cache[key] = result
	return result

static func _find_mesh(node: Node) -> MeshInstance3D:
	if node is MeshInstance3D:
		return node
	for child in node.get_children():
		var found: MeshInstance3D = _find_mesh(child)
		if found != null:
			return found
	return null

static func _nearest_face(triangles: Array, point: Vector3) -> int:
	var best: int = -1
	var best_distance: float = INF
	for i in triangles.size():
		var triangle: Array = triangles[i]
		var closest: Vector3 = _closest_point_triangle(point, triangle[0], triangle[1], triangle[2])
		var distance: float = closest.distance_squared_to(point)
		if distance < best_distance:
			best_distance = distance
			best = i
	return best

static func _closest_point_triangle(point: Vector3, a: Vector3, b: Vector3, c: Vector3) -> Vector3:
	var ab: Vector3 = b - a
	var ac: Vector3 = c - a
	var ap: Vector3 = point - a
	var d1: float = ab.dot(ap)
	var d2: float = ac.dot(ap)
	if d1 <= 0.0 and d2 <= 0.0:
		return a
	var bp: Vector3 = point - b
	var d3: float = ab.dot(bp)
	var d4: float = ac.dot(bp)
	if d3 >= 0.0 and d4 <= d3:
		return b
	var vc: float = d1 * d4 - d3 * d2
	if vc <= 0.0 and d1 >= 0.0 and d3 <= 0.0:
		return a + ab * (d1 / (d1 - d3))
	var cp: Vector3 = point - c
	var d5: float = ab.dot(cp)
	var d6: float = ac.dot(cp)
	if d6 >= 0.0 and d5 <= d6:
		return c
	var vb: float = d5 * d2 - d1 * d6
	if vb <= 0.0 and d2 >= 0.0 and d6 <= 0.0:
		return a + ac * (d2 / (d2 - d6))
	var va: float = d3 * d6 - d5 * d4
	if va <= 0.0 and d4 - d3 >= 0.0 and d5 - d6 >= 0.0:
		return b + (c - b) * ((d4 - d3) / ((d4 - d3) + (d5 - d6)))
	var denominator: float = 1.0 / (va + vb + vc)
	return a + ab * (vb * denominator) + ac * (vc * denominator)

static func _vertex_key(point: Vector3) -> String:
	return "%d:%d:%d" % [roundi(point.x * 10000.0), roundi(point.y * 10000.0), roundi(point.z * 10000.0)]
