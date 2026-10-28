class_name PCGManifoldMeshBuilder
extends RefCounted

static func ring(outer_radius: float, inner_radius: float, depth: float, segments: int = 48, texture_world_size: float = 1.0, root_flare: float = 0.0) -> ArrayMesh:
	var vertices := PackedVector3Array()
	var normals := PackedVector3Array()
	var uvs := PackedVector2Array()
	var indices := PackedInt32Array()
	var half_depth := depth * 0.5
	var world_size := maxf(texture_world_size, 0.001)
	var root_scale := 1.0 + maxf(root_flare, 0.0)
	for i in segments:
		var angle := TAU * float(i) / float(segments)
		var next_angle := TAU * float(i + 1) / float(segments)
		var radial := Vector3(cos(angle), sin(angle), 0.0)
		var next_radial := Vector3(cos(next_angle), sin(next_angle), 0.0)
		var outer_front_a := radial * outer_radius
		var outer_front_b := next_radial * outer_radius
		var outer_root_a := radial * outer_radius * root_scale
		var outer_root_b := next_radial * outer_radius * root_scale
		var inner_a := radial * inner_radius
		var inner_b := next_radial * inner_radius
		var back := Vector3(0.0, 0.0, -half_depth)
		var front := Vector3(0.0, 0.0, half_depth)
		var side_normal := (radial + Vector3.BACK * ((root_scale - 1.0) * outer_radius / depth)).normalized()
		var next_side_normal := (next_radial + Vector3.BACK * ((root_scale - 1.0) * outer_radius / depth)).normalized()
		_add_quad(
			vertices, normals, uvs, indices,
			PackedVector3Array([outer_root_a + back, outer_front_a + front, outer_front_b + front, outer_root_b + back]),
			PackedVector3Array([side_normal, side_normal, next_side_normal, next_side_normal]),
			PackedVector2Array([
				Vector2(angle * outer_radius / world_size, -half_depth / world_size),
				Vector2(angle * outer_radius / world_size, half_depth / world_size),
				Vector2(next_angle * outer_radius / world_size, half_depth / world_size),
				Vector2(next_angle * outer_radius / world_size, -half_depth / world_size),
			])
		)
		_add_quad(
			vertices, normals, uvs, indices,
			PackedVector3Array([inner_a + back, inner_b + back, inner_b + front, inner_a + front]),
			PackedVector3Array([-radial, -next_radial, -next_radial, -radial]),
			PackedVector2Array([
				Vector2(angle * inner_radius / world_size, -half_depth / world_size),
				Vector2(next_angle * inner_radius / world_size, -half_depth / world_size),
				Vector2(next_angle * inner_radius / world_size, half_depth / world_size),
				Vector2(angle * inner_radius / world_size, half_depth / world_size),
			])
		)
		_add_quad(
			vertices, normals, uvs, indices,
			PackedVector3Array([outer_front_a + front, inner_a + front, inner_b + front, outer_front_b + front]),
			PackedVector3Array([Vector3.BACK, Vector3.BACK, Vector3.BACK, Vector3.BACK]),
			_planar_uvs(PackedVector3Array([outer_front_a, inner_a, inner_b, outer_front_b]), world_size)
		)
		_add_quad(
			vertices, normals, uvs, indices,
			PackedVector3Array([outer_root_a + back, outer_root_b + back, inner_b + back, inner_a + back]),
			PackedVector3Array([Vector3.FORWARD, Vector3.FORWARD, Vector3.FORWARD, Vector3.FORWARD]),
			_planar_uvs(PackedVector3Array([outer_root_a, outer_root_b, inner_b, inner_a]), world_size)
		)
	var arrays: Array = []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = vertices
	arrays[Mesh.ARRAY_NORMAL] = normals
	arrays[Mesh.ARRAY_TEX_UV] = uvs
	arrays[Mesh.ARRAY_INDEX] = indices
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	return mesh

static func _planar_uvs(points: PackedVector3Array, world_size: float) -> PackedVector2Array:
	var result := PackedVector2Array()
	for point in points:
		result.append(Vector2(point.x, point.y) / world_size)
	return result

static func _add_quad(vertices: PackedVector3Array, normals: PackedVector3Array, uvs: PackedVector2Array, indices: PackedInt32Array, points: PackedVector3Array, face_normals: PackedVector3Array, face_uvs: PackedVector2Array) -> void:
	var base := vertices.size()
	vertices.append_array(points)
	normals.append_array(face_normals)
	uvs.append_array(face_uvs)
	indices.append_array(PackedInt32Array([base, base + 1, base + 2, base, base + 2, base + 3]))
