class_name PipeMeshBuilder
extends RefCounted

static func build(points: Array, surface_normals: Array, segments: Array, radial_segments: int, texture_world_size: float, clearance: float) -> Dictionary:
	if points.size() < 2 or points.size() != surface_normals.size():
		return {"error": "路径至少需要两个带表面法线的点。"}
	var refined: Dictionary = _refine_path(points, surface_normals, 0.18)
	var path: Array = refined["points"]
	var normals: Array = refined["normals"]
	var raw_distances: Array[float] = _distances(path)
	var total_length: float = raw_distances[-1]
	if total_length < 0.08:
		return {"error": "路径太短，无法生成管道。"}
	var radii: Array[float] = []
	var centers: Array[Vector3] = []
	for i in path.size():
		var diameter: float = _diameter_at(raw_distances[i], total_length, segments)
		radii.append(maxf(diameter, 0.02) * 0.5)
		centers.append(path[i] + normals[i].normalized() * (radii[i] + clearance))
	var tangents: Array[Vector3] = _tangents(centers)
	var frames: Array[Vector3] = _parallel_transport_frames(tangents)
	var distances: Array[float] = _distances(centers)
	var vertices := PackedVector3Array()
	var normal_array := PackedVector3Array()
	var uvs := PackedVector2Array()
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

static func _refine_path(points: Array, normals: Array, max_step: float) -> Dictionary:
	var out_points: Array[Vector3] = [points[0]]
	var out_normals: Array[Vector3] = [normals[0]]
	for i in range(points.size() - 1):
		var a: Vector3 = points[i]
		var b: Vector3 = points[i + 1]
		var steps: int = maxi(1, ceili(a.distance_to(b) / max_step))
		for step in range(1, steps + 1):
			var t: float = float(step) / float(steps)
			out_points.append(a.lerp(b, t))
			out_normals.append(normals[i].lerp(normals[i + 1], t).normalized())
	return {"points": out_points, "normals": out_normals}

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

static func _connector(position: Vector3, tangent: Vector3, radius: float, kind: String) -> Dictionary:
	return {
		"position": position,
		"tangent": tangent,
		"radius": radius * (1.32 if kind == "endpoint" else 1.42),
		"height": maxf(radius * 0.55, 0.08),
		"kind": kind
	}
