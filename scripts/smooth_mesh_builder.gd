@tool
class_name PCGSmoothMeshBuilder
extends RefCounted

static func rebuild(source: Mesh, angle_threshold_degrees: float = 50.0, uv_context: Dictionary = {}) -> ArrayMesh:
	var result := ArrayMesh.new()
	var threshold := cos(deg_to_rad(angle_threshold_degrees))
	for surface_index in source.get_surface_count():
		var arrays := source.surface_get_arrays(surface_index)
		var vertices: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
		if vertices.is_empty():
			continue
		var material := source.surface_get_material(surface_index)
		if material == null and uv_context.has("fallback_material"):
			material = uv_context["fallback_material"] as Material
		var project_host_uv: bool = material != null and material.get_meta("uv_policy", &"preserve") == &"host_surface"
		var indices: PackedInt32Array = arrays[Mesh.ARRAY_INDEX] if arrays[Mesh.ARRAY_INDEX] != null else PackedInt32Array()
		if indices.is_empty():
			for i in vertices.size():
				indices.append(i)
		var source_normals: PackedVector3Array = arrays[Mesh.ARRAY_NORMAL] if arrays[Mesh.ARRAY_NORMAL] != null else PackedVector3Array()
		var source_uvs: PackedVector2Array = arrays[Mesh.ARRAY_TEX_UV] if arrays[Mesh.ARRAY_TEX_UV] != null else PackedVector2Array()
		var has_uvs: bool = source_uvs.size() == vertices.size() or project_host_uv
		var face_count := indices.size() / 3
		var face_normals := PackedVector3Array()
		var face_areas := PackedFloat32Array()
		var face_keys: Array[PackedStringArray] = []
		var position_faces: Dictionary = {}
		face_normals.resize(face_count)
		face_areas.resize(face_count)
		face_keys.resize(face_count)
		for face in face_count:
			var corner := face * 3
			var a := vertices[indices[corner]]
			var b := vertices[indices[corner + 1]]
			var c := vertices[indices[corner + 2]]
			var cross := (b - a).cross(c - a)
			face_normals[face] = -cross.normalized()
			face_areas[face] = cross.length() * 0.5
			var keys := PackedStringArray([_vertex_key(a), _vertex_key(b), _vertex_key(c)])
			face_keys[face] = keys
			for key in keys:
				if not position_faces.has(key):
					position_faces[key] = PackedInt32Array()
				position_faces[key].append(face)
		var face_groups := PackedInt32Array()
		face_groups.resize(face_count)
		face_groups.fill(-1)
		var group_count := 0
		for face in face_count:
			if face_groups[face] >= 0:
				continue
			var stack: Array[int] = [face]
			face_groups[face] = group_count
			while not stack.is_empty():
				var current: int = stack.pop_back()
				for key in face_keys[current]:
					for neighbor in position_faces[key]:
						if face_groups[neighbor] >= 0:
							continue
						if face_normals[current].dot(face_normals[neighbor]) < threshold:
							continue
						face_groups[neighbor] = group_count
						stack.append(neighbor)
			group_count += 1
		var output_vertices := PackedVector3Array()
		var output_normals := PackedVector3Array()
		var output_uvs := PackedVector2Array()
		var output_indices := PackedInt32Array()
		var vertex_map: Dictionary = {}
		for face in face_count:
			for corner_offset in 3:
				var old_index := indices[face * 3 + corner_offset]
				var key := "%s|%d" % [_vertex_key(vertices[old_index]), face_groups[face]]
				if not vertex_map.has(key):
					vertex_map[key] = output_vertices.size()
					output_vertices.append(vertices[old_index])
					output_normals.append(Vector3.ZERO)
					var source_uv := source_uvs[old_index] if source_uvs.size() == vertices.size() else Vector2.ZERO
					output_uvs.append(_host_surface_uv(vertices[old_index], face_normals[face], material, uv_context) if project_host_uv else source_uv)
				var new_index: int = vertex_map[key]
				output_normals[new_index] += face_normals[face] * face_areas[face]
				output_indices.append(new_index)
		for i in output_normals.size():
			if output_normals[i].length_squared() < 0.0000001:
				output_normals[i] = source_normals[i] if source_normals.size() == output_normals.size() else Vector3.UP
			else:
				output_normals[i] = output_normals[i].normalized()
		var output: Array = []
		output.resize(Mesh.ARRAY_MAX)
		output[Mesh.ARRAY_VERTEX] = output_vertices
		output[Mesh.ARRAY_NORMAL] = output_normals
		output[Mesh.ARRAY_INDEX] = output_indices
		if has_uvs:
			output[Mesh.ARRAY_TEX_UV] = output_uvs
		result.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, output)
		result.surface_set_material(result.get_surface_count() - 1, material)
	return result

static func _host_surface_uv(point: Vector3, normal: Vector3, material: Material, context: Dictionary) -> Vector2:
	var world_size := maxf(float(material.get_meta("texture_world_size", 1.0)), 0.001)
	var surface_kind := int(context.get("surface_kind", 0))
	if surface_kind == 0:
		var dominant := Vector3(absf(normal.x), absf(normal.y), absf(normal.z))
		if dominant.x >= dominant.y and dominant.x >= dominant.z:
			return Vector2(point.z, point.y) / world_size
		if dominant.y >= dominant.z:
			return Vector2(point.x, point.z) / world_size
		return Vector2(point.x, point.y) / world_size
	var radius := float(context.get("cylinder_radius", 1.0))
	var cylinder_height := float(context.get("cylinder_height", 0.0))
	var angle := atan2(point.x, point.z)
	if surface_kind == 2 and point.y > cylinder_height * 0.5:
		var latitude := atan2(point.y - cylinder_height * 0.5, Vector2(point.x, point.z).length())
		return Vector2(angle * radius, latitude * radius) / world_size
	if absf(normal.y) > 0.95:
		return Vector2(point.x, point.z) / world_size
	return Vector2(angle * radius, point.y) / world_size

static func build_wireframe(source: Mesh) -> ArrayMesh:
	var result := ArrayMesh.new()
	for surface_index in source.get_surface_count():
		var arrays := source.surface_get_arrays(surface_index)
		var vertices: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
		var normals: PackedVector3Array = arrays[Mesh.ARRAY_NORMAL]
		var indices: PackedInt32Array = arrays[Mesh.ARRAY_INDEX] if arrays[Mesh.ARRAY_INDEX] != null else PackedInt32Array()
		if indices.is_empty():
			for i in vertices.size():
				indices.append(i)
		var output_vertices := PackedVector3Array()
		var output_normals := PackedVector3Array()
		var output_barycentric := PackedVector2Array()
		var output_indices := PackedInt32Array()
		var barycentric := [Vector2.ZERO, Vector2.RIGHT, Vector2.DOWN]
		for i in indices.size():
			var old_index := indices[i]
			output_vertices.append(vertices[old_index])
			output_normals.append(normals[old_index])
			output_barycentric.append(barycentric[i % 3])
			output_indices.append(i)
		var output: Array = []
		output.resize(Mesh.ARRAY_MAX)
		output[Mesh.ARRAY_VERTEX] = output_vertices
		output[Mesh.ARRAY_NORMAL] = output_normals
		output[Mesh.ARRAY_TEX_UV2] = output_barycentric
		output[Mesh.ARRAY_INDEX] = output_indices
		result.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, output)
		result.surface_set_material(result.get_surface_count() - 1, source.surface_get_material(surface_index))
	return result

static func _vertex_key(point: Vector3) -> String:
	return "%d:%d:%d" % [roundi(point.x * 100000.0), roundi(point.y * 100000.0), roundi(point.z * 100000.0)]
