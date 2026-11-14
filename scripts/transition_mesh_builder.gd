@tool
class_name PCGTransitionMeshBuilder
extends RefCounted

const OutlineGeometry = preload("res://scripts/outline_geometry.gd")

static func build(component: Node3D) -> ArrayMesh:
	var definition: PCGComponentDefinition = component.definition
	var thickness: float = component.effective_transition_thickness()
	var density: float = component.effective_transition_density()
	var segments := clampi(roundi(48.0 * density), 12, 96)
	var profile_steps := clampi(roundi(12.0 * density), 4, 24)
	var root_scale := 1.0 + definition.root_flare if definition.shape == PCGComponentDefinition.Shape.ROUND_WINDOW else 1.0
	var inner_half := (definition.size * 0.5 - Vector2.ONE * definition.frame_width * 0.25) * root_scale
	var outer_half := inner_half + Vector2.ONE * thickness
	var transition_height := minf(maxf(thickness * 0.65, 0.06), definition.depth * 0.85)
	var inner_top: Array[Vector3] = []
	var outer_top: Array[Vector3] = []
	var outer_bottom: Array[Vector3] = []
	var inner_outline := _outline_points(inner_half, definition.shape, segments)
	var outer_outline := _outline_points(outer_half, definition.shape, segments)
	for i in segments:
		var inner := inner_outline[i]
		var outer := outer_outline[i]
		inner_top.append(Vector3(inner.x, inner.y, transition_height))
		var host := _host_point(component, outer)
		outer_top.append(host["point"])
		outer_bottom.append(host["point"] - host["normal"] * 0.12)
	var rings: Array = []
	for step in range(profile_steps + 1):
		var t := float(step) / float(profile_steps)
		var arc_profile := sin(t * PI * 0.5) if component.transition_curvature >= 0.0 else 1.0 - cos(t * PI * 0.5)
		var height_t := lerpf(t, arc_profile, absf(component.transition_curvature))
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
	for ring_index in range(profile_steps + 1):
		var ring: Array = rings[ring_index]
		var previous_ring: Array = rings[maxi(ring_index - 1, 0)]
		var next_ring: Array = rings[mini(ring_index + 1, profile_steps)]
		for i in segments:
			var previous := (i - 1 + segments) % segments
			var next := (i + 1) % segments
			var outline_tangent: Vector3 = ring[next] - ring[previous]
			var profile_tangent: Vector3 = next_ring[i] - previous_ring[i]
			vertices.append(ring[i])
			normals.append(outline_tangent.cross(profile_tangent).normalized())
	for ring_index in profile_steps:
		for i in segments:
			var next := (i + 1) % segments
			var a := ring_index * segments + i
			var b := ring_index * segments + next
			var c := (ring_index + 1) * segments + i
			var d := (ring_index + 1) * segments + next
			indices.append_array(PackedInt32Array([a, c, b, b, c, d]))
	for i in segments:
		var next := (i + 1) % segments
		var inner_wall := PackedVector3Array([
			inner_top[i], inner_bottom[i], inner_bottom[next], inner_top[next]
		])
		_append_quad(vertices, normals, indices, inner_wall, _quad_normals(inner_wall))
		var bottom := PackedVector3Array([
			inner_bottom[i], outer_bottom[i], outer_bottom[next], inner_bottom[next]
		])
		_append_quad(vertices, normals, indices, bottom, _quad_normals(bottom))
		var outer_wall := PackedVector3Array([
			outer_bottom[i], outer_top[i], outer_top[next], outer_bottom[next]
		])
		_append_quad(vertices, normals, indices, outer_wall, _quad_normals(outer_wall))
	var arrays: Array = []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = vertices
	arrays[Mesh.ARRAY_NORMAL] = normals
	arrays[Mesh.ARRAY_INDEX] = indices
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	return mesh

static func _outline_points(half_size: Vector2, shape: PCGComponentDefinition.Shape, segments: int) -> Array[Vector2]:
	if shape == PCGComponentDefinition.Shape.ARCH_WINDOW:
		return OutlineGeometry.resample_closed(OutlineGeometry.arch(half_size * 2.0), segments)
	var points: Array[Vector2] = []
	for i in segments:
		points.append(_outline_point(TAU * float(i) / float(segments), half_size, shape))
	return points

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

static func _quad_normals(points: PackedVector3Array) -> PackedVector3Array:
	var normals := PackedVector3Array()
	for i in points.size():
		var previous := points[(i - 1 + points.size()) % points.size()] - points[i]
		var next := points[(i + 1) % points.size()] - points[i]
		normals.append(previous.cross(next).normalized())
	return normals

static func _append_quad(vertices: PackedVector3Array, normals: PackedVector3Array, indices: PackedInt32Array, points: PackedVector3Array, face_normals: PackedVector3Array) -> void:
	var base := vertices.size()
	vertices.append_array(points)
	normals.append_array(face_normals)
	indices.append_array(PackedInt32Array([base, base + 1, base + 2, base, base + 2, base + 3]))
