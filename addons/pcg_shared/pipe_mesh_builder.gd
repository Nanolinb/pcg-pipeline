class_name PipeMeshBuilder
extends RefCounted

static func build(points: Array, surface_normals: Array, segments: Array, radial_segments: int, texture_world_size: float, clearance: float, surface_offsets: Array = [], optimization: Dictionary = {}) -> Dictionary:
	if points.size() < 2 or points.size() != surface_normals.size():
		return {"error": "路径至少需要两个带表面法线的点。"}
	var refined: Dictionary = _refine_path(points, surface_normals, surface_offsets, segments, texture_world_size, optimization)
	var path: Array = refined["points"]
	var normals: Array = refined["normals"]
	var wall_offsets: Array = refined["wall_offsets"]
	var raw_distances: Array[float] = _distances(path)
	var total_length: float = raw_distances[-1]
	if total_length < 0.08:
		return {"error": "路径太短，无法生成管道。"}
	var radii: Array[float] = []
	var centers: Array[Vector3] = []
	for i in path.size():
		var diameter: float = _diameter_at(raw_distances[i], total_length, segments)
		radii.append(maxf(diameter, 0.02) * 0.5)
		centers.append(path[i] + normals[i].normalized() * (radii[i] + clearance + wall_offsets[i]))
	var tangents: Array[Vector3] = _tangents(centers)
	var frames: Array[Vector3] = _parallel_transport_frames(tangents)
	var distances: Array[float] = _distances(centers)
	var vertices := PackedVector3Array()
	var normal_array := PackedVector3Array()
	var uvs := PackedVector2Array()
	var uv2s := PackedVector2Array()
	var indices := PackedInt32Array()
	var ring_size: int = radial_segments + 1
	for i in centers.size():
		var tangent: Vector3 = tangents[i]
		var side: Vector3 = frames[i]
		var up: Vector3 = tangent.cross(side).normalized()
		for j in ring_size:
			var angle: float = TAU * float(j) / float(radial_segments)
			var radial: Vector3 = (side * cos(angle) + up * sin(angle)).normalized()
			vertices.append(centers[i] + radial * radii[i])
			normal_array.append(radial)
			var u: float = radii[i] * TAU * float(j) / float(radial_segments) / texture_world_size
			var v: float = distances[i] / texture_world_size
			uvs.append(Vector2(u, v))
			uv2s.append(Vector2(float(j) / float(radial_segments), distances[i] / maxf(distances[-1], 0.001)))
	for i in range(centers.size() - 1):
		for j in radial_segments:
			var a: int = i * ring_size + j
			var b: int = a + 1
			var c: int = (i + 1) * ring_size + j
			var d: int = c + 1
			indices.append_array(PackedInt32Array([a, c, b, b, c, d]))
	var arrays: Array = []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = vertices
	arrays[Mesh.ARRAY_NORMAL] = normal_array
	arrays[Mesh.ARRAY_TEX_UV] = uvs
	arrays[Mesh.ARRAY_TEX_UV2] = uv2s
	arrays[Mesh.ARRAY_INDEX] = indices
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	var connectors: Array = []
	connectors.append(_connector(centers[0], tangents[0], radii[0], "endpoint"))
	connectors.append(_connector(centers[-1], tangents[-1], radii[-1], "endpoint"))
	for segment_index in range(segments.size() - 1):
		var boundary: float = float(segments[segment_index]["end"]) * total_length
		var closest: int = _closest_distance_index(raw_distances, boundary)
		var radius: float = maxf(float(segments[segment_index]["diameter"]), float(segments[segment_index + 1]["diameter"])) * 0.5
		connectors.append(_connector(centers[closest], tangents[closest], radius, "flange"))
	return {
		"mesh": mesh,
		"connectors": connectors,
		"length": distances[-1],
		"vertex_count": vertices.size(),
		"centers": centers
	}

static func _refine_path(points: Array, normals: Array, surface_offsets: Array, segments: Array, texture_world_size: float, optimization: Dictionary) -> Dictionary:
	var out_points: Array[Vector3] = [points[0]]
	var out_normals: Array[Vector3] = [normals[0]]
	var out_offsets: Array[float] = [surface_offsets[0] if surface_offsets.size() == points.size() else 0.0]
	var automatic: bool = optimization.get("auto", true)
	var texture_link: bool = optimization.get("texture_link", true)
	var straight_step: float = optimization.get("straight_step", 4.0)
	var curve_step: float = optimization.get("curve_step", 0.28)
	if texture_link:
		straight_step *= texture_world_size
		curve_step *= texture_world_size
	var threshold: float = deg_to_rad(optimization.get("straight_angle", 3.0))
	var total_length: float = _distances(points)[-1]
	var travelled: float = 0.0
	for i in range(points.size() - 1):
		var a: Vector3 = points[i]
		var b: Vector3 = points[i + 1]
		var length: float = a.distance_to(b)
		var step_size: float = optimization.get("manual_step", 0.18)
		if automatic:
			var direction: Vector3 = (b - a).normalized()
			var before: Vector3 = direction if i == 0 else (a - points[i - 1]).normalized()
			var after: Vector3 = direction if i == points.size() - 2 else (points[i + 2] - b).normalized()
			var turn: float = maxf(before.angle_to(direction), direction.angle_to(after))
			var normal_turn: float = normals[i].angle_to(normals[i + 1])
			var diameter_change: bool = absf(_diameter_at(travelled, total_length, segments) - _diameter_at(travelled + length, total_length, segments)) > 0.001
			var offset_change: bool = surface_offsets.size() == points.size() and absf(surface_offsets[i] - surface_offsets[i + 1]) > 0.001
			var straight: bool = turn <= threshold and normal_turn <= threshold and not diameter_change and not offset_change
			step_size = straight_step if straight else curve_step
		var steps: int = maxi(1, ceili(length / maxf(step_size, 0.01)))
		for step in range(1, steps + 1):
			var t: float = float(step) / float(steps)
			out_points.append(a.lerp(b, t))
			out_normals.append(normals[i].lerp(normals[i + 1], t).normalized())
			out_offsets.append(lerpf(surface_offsets[i], surface_offsets[i + 1], t) if surface_offsets.size() == points.size() else 0.0)
		travelled += length
	return {"points": out_points, "normals": out_normals, "wall_offsets": out_offsets}

static func _distances(points: Array) -> Array[float]:
	var result: Array[float] = [0.0]
	for i in range(1, points.size()):
		result.append(result[-1] + points[i - 1].distance_to(points[i]))
	return result

static func _tangents(points: Array) -> Array[Vector3]:
	var result: Array[Vector3] = []
	for i in points.size():
		var tangent: Vector3
		if i == 0:
			tangent = points[1] - points[0]
		elif i == points.size() - 1:
			tangent = points[i] - points[i - 1]
		else:
			tangent = points[i + 1] - points[i - 1]
		if tangent.length_squared() < 0.000001:
			tangent = Vector3.FORWARD
		result.append(tangent.normalized())
	return result

static func _parallel_transport_frames(tangents: Array) -> Array[Vector3]:
	var initial: Vector3 = tangents[0].cross(Vector3.UP)
	if initial.length_squared() < 0.001:
		initial = tangents[0].cross(Vector3.RIGHT)
	var result: Array[Vector3] = [initial.normalized()]
	for i in range(1, tangents.size()):
		var rotation := Quaternion(tangents[i - 1], tangents[i])
		var side: Vector3 = (rotation * result[i - 1]).normalized()
		side = (side - tangents[i] * side.dot(tangents[i])).normalized()
		result.append(side)
	return result

static func _diameter_at(distance: float, total_length: float, segments: Array) -> float:
	var transition_half: float = minf(0.3, total_length * 0.025)
	for i in range(segments.size() - 1):
		var boundary: float = float(segments[i]["end"]) * total_length
		if absf(distance - boundary) <= transition_half:
			var t: float = clampf((distance - boundary + transition_half) / (2.0 * transition_half), 0.0, 1.0)
			t = t * t * (3.0 - 2.0 * t)
			return lerpf(float(segments[i]["diameter"]), float(segments[i + 1]["diameter"]), t)
	for segment in segments:
		if distance <= float(segment["end"]) * total_length:
			return float(segment["diameter"])
	return float(segments[-1]["diameter"])

static func _closest_distance_index(distances: Array, target: float) -> int:
	var best: int = 0
	var best_distance: float = INF
	for i in distances.size():
		var difference: float = absf(distances[i] - target)
		if difference < best_distance:
			best_distance = difference
			best = i
	return best

static func connector_mesh(data: Dictionary, radial_segments: int, texture_world_size: float) -> ArrayMesh:
	var cylinder := CylinderMesh.new()
	cylinder.top_radius = data["radius"]
	cylinder.bottom_radius = data["radius"]
	cylinder.height = data["height"]
	cylinder.radial_segments = radial_segments
	var result := ArrayMesh.new()
	var world_size := maxf(texture_world_size, 0.001)
	for surface_index in cylinder.get_surface_count():
		var arrays := cylinder.surface_get_arrays(surface_index)
		var vertices: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
		var normals: PackedVector3Array = arrays[Mesh.ARRAY_NORMAL]
		var uvs := PackedVector2Array()
		uvs.resize(vertices.size())
		for index in vertices.size():
			var point := vertices[index]
			if absf(normals[index].y) > 0.7:
				uvs[index] = Vector2(point.x, point.z) / world_size
			else:
				uvs[index] = Vector2(atan2(point.x, point.z) * float(data["radius"]), point.y) / world_size
		arrays[Mesh.ARRAY_TEX_UV] = uvs
		result.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	return result

static func _connector(position: Vector3, tangent: Vector3, radius: float, kind: String) -> Dictionary:
	return {
		"position": position,
		"tangent": tangent,
		"radius": radius * (1.32 if kind == "endpoint" else 1.42),
		"height": maxf(radius * 0.55, 0.08),
		"kind": kind
	}
