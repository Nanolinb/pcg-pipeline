class_name PCGManifoldMeshBuilder
extends RefCounted

static func ring(outer_radius: float, inner_radius: float, depth: float, segments: int = 48) -> ArrayMesh:
	var vertices := PackedVector3Array()
	var normals := PackedVector3Array()
	var indices := PackedInt32Array()
	var half_depth := depth * 0.5
	for i in segments:
		var angle := TAU * float(i) / float(segments)
		var radial := Vector3(cos(angle), sin(angle), 0.0)
		vertices.append(radial * outer_radius + Vector3(0.0, 0.0, -half_depth))
		vertices.append(radial * outer_radius + Vector3(0.0, 0.0, half_depth))
		vertices.append(radial * inner_radius + Vector3(0.0, 0.0, -half_depth))
		vertices.append(radial * inner_radius + Vector3(0.0, 0.0, half_depth))
		for j in 4:
			normals.append(radial if j < 2 else -radial)
	for i in segments:
		var next := (i + 1) % segments
		var a := i * 4
		var b := next * 4
		indices.append_array(PackedInt32Array([a, a + 1, b + 1, a, b + 1, b]))
		indices.append_array(PackedInt32Array([a + 2, b + 3, a + 3, a + 2, b + 2, b + 3]))
		indices.append_array(PackedInt32Array([a + 1, a + 3, b + 1, b + 1, a + 3, b + 3]))
		indices.append_array(PackedInt32Array([a, b + 2, a + 2, a, b, b + 2]))
	var arrays: Array = []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = vertices
	arrays[Mesh.ARRAY_NORMAL] = normals
	arrays[Mesh.ARRAY_INDEX] = indices
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	return mesh
