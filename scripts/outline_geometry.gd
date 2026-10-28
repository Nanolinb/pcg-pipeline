@tool
class_name PCGOutlineGeometry
extends RefCounted

static func arch(size: Vector2, arc_segments: int = 24) -> Array[Vector2]:
	var half := size * 0.5
	var shoulder_y := half.y / 3.0
	var arc_height := size.y / 3.0
	var points: Array[Vector2] = [
		Vector2(-half.x, -half.y),
		Vector2(half.x, -half.y),
	]
	for i in range(arc_segments + 1):
		var angle := PI * float(i) / float(arc_segments)
		points.append(Vector2(cos(angle) * half.x, shoulder_y + sin(angle) * arc_height))
	return points

static func resample_closed(points: Array[Vector2], segments: int) -> Array[Vector2]:
	var result: Array[Vector2] = []
	if points.size() < 2:
		return result
	var lengths := PackedFloat32Array([0.0])
	for i in points.size():
		lengths.append(lengths[-1] + points[i].distance_to(points[(i + 1) % points.size()]))
	var perimeter := lengths[-1]
	if perimeter <= 0.000001:
		return result
	for sample in segments:
		var target := perimeter * float(sample) / float(segments)
		for edge in points.size():
			if target <= lengths[edge + 1] or edge == points.size() - 1:
				var edge_length := lengths[edge + 1] - lengths[edge]
				var t := (target - lengths[edge]) / maxf(edge_length, 0.000001)
				result.append(points[edge].lerp(points[(edge + 1) % points.size()], t))
				break
	return result

static func ring(outer_size: Vector2, inner_size: Vector2, depth: float, segments: int = 48, texture_world_size: float = 1.0) -> ArrayMesh:
	var outer := resample_closed(arch(outer_size), segments)
	var inner := resample_closed(arch(inner_size), segments)
	var vertices := PackedVector3Array()
	var indices := PackedInt32Array()
	var back := -depth * 0.5
	var front := depth * 0.5
	for i in segments:
		vertices.append_array(PackedVector3Array([
			Vector3(outer[i].x, outer[i].y, back), Vector3(outer[i].x, outer[i].y, front),
			Vector3(inner[i].x, inner[i].y, back), Vector3(inner[i].x, inner[i].y, front)
		]))
	for i in segments:
		var next := (i + 1) % segments
		var a := i * 4
		var b := next * 4
		indices.append_array(PackedInt32Array([a, a + 1, b + 1, a, b + 1, b]))
		indices.append_array(PackedInt32Array([a + 2, b + 2, b + 3, a + 2, b + 3, a + 3]))
		indices.append_array(PackedInt32Array([a + 1, a + 3, b + 3, a + 1, b + 3, b + 1]))
		indices.append_array(PackedInt32Array([a, b, b + 2, a, b + 2, a + 2]))
	var arrays := _surface_data(vertices, indices, texture_world_size)
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	return mesh

static func solid(size: Vector2, depth: float, segments: int = 48, texture_world_size: float = 1.0) -> ArrayMesh:
	var outline := resample_closed(arch(size), segments)
	var vertices := PackedVector3Array()
	var indices := PackedInt32Array()
	var back := -depth * 0.5
	var front := depth * 0.5
	for point in outline:
		vertices.append(Vector3(point.x, point.y, back))
		vertices.append(Vector3(point.x, point.y, front))
	vertices.append(Vector3(0.0, 0.0, back))
	vertices.append(Vector3(0.0, 0.0, front))
	for i in segments:
		var next := (i + 1) % segments
		indices.append_array(PackedInt32Array([i * 2, i * 2 + 1, next * 2 + 1, i * 2, next * 2 + 1, next * 2]))
	for i in segments:
		var next := (i + 1) % segments
		indices.append_array(PackedInt32Array([segments * 2, next * 2 + 1, i * 2 + 1]))
		indices.append_array(PackedInt32Array([segments * 2, i * 2, next * 2]))
	var arrays := _surface_data(vertices, indices, texture_world_size)
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	return mesh

static func _surface_data(vertices: PackedVector3Array, indices: PackedInt32Array, _world_size: float) -> Array:
	var surface := SurfaceTool.new()
	surface.begin(Mesh.PRIMITIVE_TRIANGLES)
	for index in indices:
		surface.set_uv(Vector2(vertices[index].x, vertices[index].y))
		surface.add_vertex(vertices[index])
	surface.index()
	surface.generate_normals()
	return surface.commit().surface_get_arrays(0)
