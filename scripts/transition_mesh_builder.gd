class_name PCGTransitionMeshBuilder
extends RefCounted

static func build(component: Node3D) -> ArrayMesh:
	var definition: PCGComponentDefinition = component.definition
	var thickness: float = component.effective_transition_thickness()
	var segments := 48
	var profile_steps := 12
	var root_scale := 1.0 + definition.root_flare if definition.shape == PCGComponentDefinition.Shape.ROUND_WINDOW else 1.0
	var inner_half := (definition.size * 0.5 - Vector2.ONE * definition.frame_width * 0.25) * root_scale
	var outer_half := inner_half + Vector2.ONE * thickness
	var inner_top: Array[Vector3] = []
	var outer_top: Array[Vector3] = []
	var outer_bottom: Array[Vector3] = []
	for i in segments:
		var angle := TAU * float(i) / float(segments)
		var inner := _outline_point(angle, inner_half, definition.shape)
		var outer := _outline_point(angle, outer_half, definition.shape)
		inner_top.append(Vector3(inner.x, inner.y, -definition.root_embed))
		var host := _host_point(component, outer)
		outer_top.append(host["point"])
		outer_bottom.append(host["point"] - host["normal"] * 0.12)
	var rings: Array = []
	for step in range(profile_steps + 1):
		var t := float(step) / float(profile_steps)
		var height_t := pow(t, lerpf(2.1, 0.72, component.transition_curvature))
		var ring: Array[Vector3] = []
		for i in segments:
			var point := outer_top[i].lerp(inner_top[i], t)
			point.z = lerpf(outer_top[i].z, inner_top[i].z, height_t)
			ring.append(point)
		rings.append(ring)
	var inner_bottom: Array[Vector3] = []
	for point in inner_top:
		inner_bottom.append(point - Vector3(0.0, 0.0, 0.12))
	rings.append(inner_bottom)
	rings.append(outer_bottom)
	var vertices := PackedVector3Array()
	var normals := PackedVector3Array()
	var indices := PackedInt32Array()
	for ring in rings:
		for point in ring:
			vertices.append(point)
			normals.append(Vector3.UP)
	for ring_index in range(rings.size() - 1):
		for i in segments:
			var next := (i + 1) % segments
			var a := ring_index * segments + i
			var b := ring_index * segments + next
			var c := (ring_index + 1) * segments + i
			var d := (ring_index + 1) * segments + next
			_add_quad(indices, a, b, c, d, ring_index == profile_steps)
	var last_ring := rings.size() - 1
	for i in segments:
		var next := (i + 1) % segments
		_add_quad(indices, last_ring * segments + i, last_ring * segments + next, i, next, true)
	var arrays: Array = []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = vertices
	arrays[Mesh.ARRAY_NORMAL] = normals
	arrays[Mesh.ARRAY_INDEX] = indices
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	return mesh

static func _outline_point(angle: float, half_size: Vector2, shape: PCGComponentDefinition.Shape) -> Vector2:
	var direction := Vector2(cos(angle), sin(angle))
	if shape == PCGComponentDefinition.Shape.ROUND_WINDOW:
		return direction * half_size.x
	var divisor := maxf(absf(direction.x), absf(direction.y))
	return Vector2(direction.x * half_size.x, direction.y * half_size.y) / maxf(divisor, 0.0001)

static func _host_point(component: Node3D, outline: Vector2) -> Dictionary:
	var wall: Node3D = component.wall
	var base_transform: Transform3D = wall.surface_transform(component.anchor)
	var component_transform := component.global_transform
	if absf(component_transform.basis.determinant()) < 0.000001:
		component_transform.basis = base_transform.basis
	var approximate_world: Vector3 = component_transform * Vector3(outline.x, outline.y, 0.0)
	var tangent_offset: Vector3 = base_transform.basis.inverse() * (approximate_world - base_transform.origin)
	var host_anchor: Vector2 = component.anchor + Vector2(tangent_offset.x, tangent_offset.y)
	var host_transform: Transform3D = wall.surface_transform(host_anchor)
	var world_point := host_transform.origin - host_transform.basis.z * 0.025
	return {
		"point": component_transform.affine_inverse() * world_point,
		"normal": (component_transform.basis.inverse() * host_transform.basis.z).normalized(),
	}

static func _add_quad(indices: PackedInt32Array, a: int, b: int, c: int, d: int, reverse: bool) -> void:
	if reverse:
		indices.append_array(PackedInt32Array([a, b, c, b, d, c]))
	else:
		indices.append_array(PackedInt32Array([a, c, b, b, c, d]))
