class_name PCGMeshChunkBaker
extends RefCounted

var chunk_size: float
var _groups: Dictionary = {}

func _init(size_meters: float = 8.0) -> void:
	chunk_size = maxf(size_meters, 0.1)

func append(source: Mesh, transform: Transform3D = Transform3D.IDENTITY, material_override: Material = null) -> void:
	if source == null:
		return
	for surface_index in source.get_surface_count():
		var arrays := source.surface_get_arrays(surface_index)
		var source_vertices: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
		if source_vertices.is_empty():
			continue
		var material: Material = material_override if material_override != null else source.surface_get_material(surface_index)
		var source_indices: PackedInt32Array = arrays[Mesh.ARRAY_INDEX] if arrays[Mesh.ARRAY_INDEX] != null else PackedInt32Array()
		if source_indices.is_empty():
			for index in source_vertices.size():
				source_indices.append(index)
		var normal_basis := transform.basis.inverse().transposed()
		for corner in range(0, source_indices.size(), 3):
			var a := transform * source_vertices[source_indices[corner]]
			var b := transform * source_vertices[source_indices[corner + 1]]
			var c := transform * source_vertices[source_indices[corner + 2]]
			var center := (a + b + c) / 3.0
			var coord := Vector3i(
				floori(center.x / chunk_size),
				floori(center.y / chunk_size),
				floori(center.z / chunk_size)
			)
			var group := _group_for(coord, material)
			for offset in 3:
				_append_vertex(group, arrays, source_indices[corner + offset], transform, normal_basis, surface_index)

func build() -> Array[Dictionary]:
	var chunks: Array[Dictionary] = []
	for group in _groups.values():
		var arrays: Array = []
		arrays.resize(Mesh.ARRAY_MAX)
		arrays[Mesh.ARRAY_VERTEX] = group["vertices"]
		arrays[Mesh.ARRAY_NORMAL] = group["normals"]
		arrays[Mesh.ARRAY_TEX_UV] = group["uvs"]
		arrays[Mesh.ARRAY_INDEX] = group["indices"]
		if not group["uv2s"].is_empty():
			arrays[Mesh.ARRAY_TEX_UV2] = group["uv2s"]
		if not group["colors"].is_empty():
			arrays[Mesh.ARRAY_COLOR] = group["colors"]
		if not group["tangents"].is_empty():
			arrays[Mesh.ARRAY_TANGENT] = group["tangents"]
		var mesh := ArrayMesh.new()
		mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
		mesh.surface_set_material(0, group["material"])
		chunks.append({"coord": group["coord"], "mesh": mesh, "material": group["material"]})
	return chunks

func _group_for(coord: Vector3i, material: Material) -> Dictionary:
	var key := "%s|%s" % [coord, MaterialLibrary.batch_key(material)]
	if _groups.has(key):
		return _groups[key]
	var group := {
		"coord": coord,
		"material": material,
		"vertices": PackedVector3Array(),
		"normals": PackedVector3Array(),
		"uvs": PackedVector2Array(),
		"uv2s": PackedVector2Array(),
		"colors": PackedColorArray(),
		"tangents": PackedFloat32Array(),
		"indices": PackedInt32Array(),
		"lookup": {},
	}
	_groups[key] = group
	return group

func _append_vertex(group: Dictionary, source: Array, old_index: int, transform: Transform3D, normal_basis: Basis, surface_index: int) -> void:
	var lookup: Dictionary = group["lookup"]
	var indices: PackedInt32Array = group["indices"]
	var lookup_key := "%d:%d" % [surface_index, old_index]
	if lookup.has(lookup_key):
		indices.append(lookup[lookup_key])
		group["indices"] = indices
		return
	var new_index: int = group["vertices"].size()
	lookup[lookup_key] = new_index
	indices.append(new_index)
	group["indices"] = indices
	var vertices: PackedVector3Array = group["vertices"]
	vertices.append(transform * source[Mesh.ARRAY_VERTEX][old_index])
	group["vertices"] = vertices
	var normals: PackedVector3Array = group["normals"]
	var source_normals = source[Mesh.ARRAY_NORMAL]
	normals.append((normal_basis * source_normals[old_index]).normalized() if source_normals != null and source_normals.size() > old_index else Vector3.UP)
	group["normals"] = normals
	var uvs: PackedVector2Array = group["uvs"]
	var source_uvs = source[Mesh.ARRAY_TEX_UV]
	uvs.append(source_uvs[old_index] if source_uvs != null and source_uvs.size() > old_index else Vector2.ZERO)
	group["uvs"] = uvs
	var source_uv2s = source[Mesh.ARRAY_TEX_UV2]
	if source_uv2s != null and source_uv2s.size() > old_index:
		var uv2s: PackedVector2Array = group["uv2s"]
		uv2s.append(source_uv2s[old_index])
		group["uv2s"] = uv2s
	var source_colors = source[Mesh.ARRAY_COLOR]
	if source_colors != null and source_colors.size() > old_index:
		var colors: PackedColorArray = group["colors"]
		colors.append(source_colors[old_index])
		group["colors"] = colors
	var source_tangents = source[Mesh.ARRAY_TANGENT]
	if source_tangents != null and source_tangents.size() >= (old_index + 1) * 4:
		var tangents: PackedFloat32Array = group["tangents"]
		var tangent := (transform.basis * Vector3(source_tangents[old_index * 4], source_tangents[old_index * 4 + 1], source_tangents[old_index * 4 + 2])).normalized()
		tangents.append_array(PackedFloat32Array([tangent.x, tangent.y, tangent.z, source_tangents[old_index * 4 + 3]]))
		group["tangents"] = tangents
