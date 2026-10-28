class_name PCGFusedWall
extends Node3D

const SmoothMeshBuilder = preload("res://scripts/smooth_mesh_builder.gd")

enum SurfaceKind {
	PLANE,
	CYLINDER,
	DOME_CYLINDER,
}

var surface_kind: SurfaceKind = SurfaceKind.PLANE
var display_name: String = "平面主体墙"
var wall_size := Vector3(6.0, 4.6, 0.36)
var cylinder_radius: float = 1.35
var cylinder_height: float = 3.8
var cylinder_depth: float = 0.7
var body_color := Color("3d777b")
var transition_density: float = 1.0
var thickness: float:
	get:
		return wall_size.z if surface_kind == SurfaceKind.PLANE else cylinder_depth
var combiner: CSGCombiner3D
var body: CSGShape3D
var body_material: StandardMaterial3D
var base_shapes: Array[CSGShape3D] = []
var outline: MeshInstance3D
var outline_parts: Array[MeshInstance3D] = []
var render_root: Node3D
var render_mesh: MeshInstance3D
var render_meshes: Array[MeshInstance3D] = []
var render_transform := Transform3D.IDENTITY
var solid_mesh: ArrayMesh
var wireframe_material: ShaderMaterial
var wireframe_enabled: bool = false
var render_dirty: bool = true
var render_cooldown: float = 0.0
var render_refresh_interval: float = 0.1
var preview_mode: bool = false
var base_preview_root: Node3D
var base_preview_meshes: Array[MeshInstance3D] = []
var components: Array = []

func _ready() -> void:
	name = display_name
	combiner = CSGCombiner3D.new()
	combiner.name = "WatertightFusion"
	add_child(combiner)
	body_material = MaterialLibrary.solid(StringName("host_surface_%d" % surface_kind), body_color, 0.78, 0.0, &"host_surface", 1.0)
	var material := body_material
	if surface_kind != SurfaceKind.PLANE:
		var cylinder := CSGCylinder3D.new()
		cylinder.radius = cylinder_radius
		cylinder.height = cylinder_height
		cylinder.sides = 64
		body = cylinder
		_add_base_shape(body, material)
		if surface_kind == SurfaceKind.DOME_CYLINDER:
			var dome := CSGSphere3D.new()
			dome.radius = cylinder_radius
			dome.radial_segments = 64
			dome.rings = 32
			dome.position.y = cylinder_height * 0.5
			_add_base_shape(dome, material)
	else:
		var box := CSGBox3D.new()
		box.size = wall_size
		body = box
		_add_base_shape(body, material)
	_build_outline()
	_build_render_mesh()

func _add_base_shape(shape: CSGShape3D, material: Material) -> void:
	shape.name = "SolidSurface"
	shape.operation = CSGShape3D.OPERATION_UNION
	shape.material = material
	base_shapes.append(shape)
	combiner.add_child(shape)

func _build_render_mesh() -> void:
	combiner.visible = false
	render_root = Node3D.new()
	render_root.name = "SmoothedFusionChunks"
	add_child(render_root)
	wireframe_material = MaterialLibrary.shader(&"editor/watertight_wireframe", preload("res://shaders/wireframe.gdshader"))
	_build_base_preview()
	mark_geometry_dirty()

func _build_base_preview() -> void:
	base_preview_root = Node3D.new()
	base_preview_root.name = "UnfusedEditPreview"
	base_preview_root.visible = false
	add_child(base_preview_root)
	for shape in base_shapes:
		var instance := MeshInstance3D.new()
		if shape is CSGBox3D:
			var mesh := BoxMesh.new()
			mesh.size = shape.size
			instance.mesh = mesh
		elif shape is CSGCylinder3D:
			var mesh := CylinderMesh.new()
			mesh.top_radius = shape.radius
			mesh.bottom_radius = shape.radius
			mesh.height = shape.height
			mesh.radial_segments = shape.sides
			instance.mesh = mesh
		elif shape is CSGSphere3D:
			var mesh := SphereMesh.new()
			mesh.radius = shape.radius
			mesh.height = shape.radius * 2.0
			mesh.radial_segments = shape.radial_segments
			mesh.rings = shape.rings
			instance.mesh = mesh
		instance.material_override = body_material
		instance.transform = shape.transform
		instance.set_meta("source_mesh", instance.mesh)
		base_preview_root.add_child(instance)
		base_preview_meshes.append(instance)

func set_preview_mode(value: bool) -> void:
	preview_mode = value
	base_preview_root.visible = value
	render_root.visible = not value
	for component in components:
		component.set_direct_preview(value)
		if not value:
			merge_component(component)
	if not value:
		flush_geometry()

func merge_component(component: Node3D) -> void:
	if not components.has(component):
		components.append(component)
	if component.active:
		_attach_shapes(component)
	else:
		_detach_shapes(component)
	_reorder()
	component.apply_csg_state()
	render_root.visible = true
	base_preview_root.visible = false
	flush_geometry()

func mark_geometry_dirty() -> void:
	if not preview_mode:
		render_dirty = true

func flush_geometry() -> void:
	render_dirty = true
	render_cooldown = 0.0

func _process(delta: float) -> void:
	if not render_dirty:
		return
	render_cooldown = maxf(render_cooldown - delta, 0.0)
	if render_cooldown <= 0.0:
		render_dirty = false
		render_cooldown = render_refresh_interval
		call_deferred("_refresh_render_mesh")

func _refresh_render_mesh() -> void:
	if not is_inside_tree() or combiner == null:
		return
	var meshes := combiner.get_meshes()
	if meshes.size() < 2 or not meshes[1] is Mesh:
		render_dirty = true
		return
	render_transform = meshes[0]
	solid_mesh = SmoothMeshBuilder.rebuild(meshes[1], 50.0, {
		"surface_kind": surface_kind,
		"cylinder_radius": cylinder_radius,
		"cylinder_height": cylinder_height,
		"fallback_material": body_material,
	})
	_rebuild_render_chunks()

func set_wireframe(enabled: bool) -> void:
	wireframe_enabled = enabled
	for instance in base_preview_meshes:
		var source: Mesh = instance.get_meta("source_mesh")
		instance.mesh = SmoothMeshBuilder.build_wireframe(source) if enabled else source
		instance.material_override = wireframe_material if enabled else body_material
	if render_mesh != null:
		for instance in render_meshes:
			instance.material_override = wireframe_material if enabled else null
		if solid_mesh != null:
			_rebuild_render_chunks()

func _rebuild_render_chunks() -> void:
	if render_root == null:
		return
	for child in render_root.get_children():
		render_root.remove_child(child)
		child.free()
	render_meshes.clear()
	render_mesh = null
	if solid_mesh == null:
		return
	var source := SmoothMeshBuilder.build_wireframe(solid_mesh) if wireframe_enabled else solid_mesh
	var baker := PCGMeshChunkBaker.new(8.0)
	baker.append(source, render_transform, wireframe_material if wireframe_enabled else null)
	for chunk in baker.build():
		var instance := MeshInstance3D.new()
		var coord: Vector3i = chunk["coord"]
		instance.name = "RenderChunk_%d_%d_%d" % [coord.x, coord.y, coord.z]
		instance.mesh = chunk["mesh"]
		instance.material_override = wireframe_material if wireframe_enabled else null
		render_root.add_child(instance)
		render_meshes.append(instance)
		if render_mesh == null:
			render_mesh = instance

func _build_outline() -> void:
	if surface_kind != SurfaceKind.PLANE:
		var cylinder := CylinderMesh.new()
		cylinder.top_radius = cylinder_radius
		cylinder.bottom_radius = cylinder_radius
		cylinder.height = cylinder_height
		cylinder.radial_segments = 64
		outline = _create_outline_part(cylinder, Vector3.ZERO)
		if surface_kind == SurfaceKind.DOME_CYLINDER:
			var dome := SphereMesh.new()
			dome.radius = cylinder_radius
			dome.height = cylinder_radius * 2.0
			dome.radial_segments = 64
			dome.rings = 32
			_create_outline_part(dome, Vector3(0.0, cylinder_height * 0.5, 0.0))
	else:
		var box := BoxMesh.new()
		box.size = wall_size
		outline = _create_outline_part(box, Vector3.ZERO)

func _create_outline_part(mesh: Mesh, local_position: Vector3) -> MeshInstance3D:
	var part := MeshInstance3D.new()
	part.name = "AttachmentOutline"
	part.mesh = mesh
	part.position = local_position
	part.material_override = MaterialLibrary.shader(&"editor/attachment_outline", preload("res://shaders/attachment_outline.gdshader"))
	part.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	part.visible = false
	outline_parts.append(part)
	add_child(part)
	return part

func surface_transform(anchor: Vector2) -> Transform3D:
	if surface_kind != SurfaceKind.PLANE:
		var angle := anchor.x / cylinder_radius
		if surface_kind == SurfaceKind.DOME_CYLINDER and anchor.y > cylinder_height * 0.5:
			var latitude := (anchor.y - cylinder_height * 0.5) / cylinder_radius
			var normal := Vector3(sin(angle) * cos(latitude), sin(latitude), cos(angle) * cos(latitude)).normalized()
			var point := Vector3(0.0, cylinder_height * 0.5, 0.0) + normal * cylinder_radius
			return global_transform * Transform3D(_radial_basis(angle, normal), point)
		var point := Vector3(sin(angle) * cylinder_radius, anchor.y, cos(angle) * cylinder_radius)
		var normal := Vector3(sin(angle), 0.0, cos(angle))
		return global_transform * Transform3D(_radial_basis(angle, normal), point)
	return global_transform * Transform3D(Basis.IDENTITY, Vector3(anchor.x, anchor.y, thickness * 0.5))

func _radial_basis(angle: float, normal: Vector3) -> Basis:
	var x := Vector3(cos(angle), 0.0, -sin(angle)).normalized()
	var y := normal.cross(x).normalized()
	return Basis(x, y, normal)

func ray_anchor(origin: Vector3, direction: Vector3) -> Dictionary:
	if surface_kind == SurfaceKind.DOME_CYLINDER:
		var cylinder_hit := _ray_cylinder(origin, direction)
		var dome_hit := _ray_dome(origin, direction)
		if cylinder_hit.is_empty():
			return dome_hit
		if dome_hit.is_empty():
			return cylinder_hit
		var cylinder_distance := origin.distance_to(cylinder_hit["position"])
		var dome_distance := origin.distance_to(dome_hit["position"])
		return dome_hit if dome_distance < cylinder_distance else cylinder_hit
	if surface_kind == SurfaceKind.CYLINDER:
		return _ray_cylinder(origin, direction)
	var normal := global_basis.z.normalized()
	var plane := Plane(normal, global_position + global_basis.z * thickness * 0.5)
	var point: Variant = plane.intersects_ray(origin, direction)
	if point == null:
		return {}
	var local := to_local(point)
	if absf(local.x) > wall_size.x * 0.5 or absf(local.y) > wall_size.y * 0.5:
		return {}
	return {"anchor": Vector2(local.x, local.y), "position": point, "normal": normal, "host": self}

func _ray_cylinder(origin: Vector3, direction: Vector3) -> Dictionary:
	var local_origin := to_local(origin)
	var local_direction := global_basis.inverse() * direction
	var a := local_direction.x * local_direction.x + local_direction.z * local_direction.z
	if a < 0.0000001:
		return {}
	var b := 2.0 * (local_origin.x * local_direction.x + local_origin.z * local_direction.z)
	var c := local_origin.x * local_origin.x + local_origin.z * local_origin.z - cylinder_radius * cylinder_radius
	var discriminant := b * b - 4.0 * a * c
	if discriminant < 0.0:
		return {}
	var root := sqrt(discriminant)
	var distances := [(-b - root) / (2.0 * a), (-b + root) / (2.0 * a)]
	for distance in distances:
		if distance < 0.0:
			continue
		var local_point: Vector3 = local_origin + local_direction * float(distance)
		if absf(local_point.y) > cylinder_height * 0.5:
			continue
		var local_normal := Vector3(local_point.x, 0.0, local_point.z).normalized()
		var angle := atan2(local_point.x, local_point.z)
		return {
			"anchor": Vector2(angle * cylinder_radius, local_point.y),
			"position": to_global(local_point),
			"normal": (global_basis * local_normal).normalized(),
			"host": self,
		}
	return {}

func _ray_dome(origin: Vector3, direction: Vector3) -> Dictionary:
	var local_origin := to_local(origin)
	var local_direction := global_basis.inverse() * direction
	var center := Vector3(0.0, cylinder_height * 0.5, 0.0)
	var offset := local_origin - center
	var a := local_direction.length_squared()
	var b := 2.0 * offset.dot(local_direction)
	var c := offset.length_squared() - cylinder_radius * cylinder_radius
	var discriminant := b * b - 4.0 * a * c
	if a < 0.0000001 or discriminant < 0.0:
		return {}
	var root := sqrt(discriminant)
	var distances := [(-b - root) / (2.0 * a), (-b + root) / (2.0 * a)]
	for distance in distances:
		if distance < 0.0:
			continue
		var local_point: Vector3 = local_origin + local_direction * float(distance)
		if local_point.y < cylinder_height * 0.5 - 0.0001:
			continue
		var local_normal := (local_point - center).normalized()
		var latitude := atan2(local_point.y - center.y, Vector2(local_point.x, local_point.z).length())
		var angle := atan2(local_point.x, local_point.z)
		return {
			"anchor": Vector2(angle * cylinder_radius, center.y + latitude * cylinder_radius),
			"position": to_global(local_point),
			"normal": (global_basis * local_normal).normalized(),
			"host": self,
		}
	return {}

func clamp_anchor(anchor: Vector2, definition: PCGComponentDefinition) -> Vector2:
	if surface_kind != SurfaceKind.PLANE:
		var half_arc := PI * cylinder_radius
		var wrapped_x := fposmod(anchor.x + half_arc, half_arc * 2.0) - half_arc
		var lower := -cylinder_height * 0.5 + definition.size.y * 0.5 + 0.05
		var upper := cylinder_height * 0.5 - definition.size.y * 0.5 - 0.05
		if surface_kind == SurfaceKind.DOME_CYLINDER:
			upper = cylinder_height * 0.5 + cylinder_radius * PI * 0.5 - 0.05
		return Vector2(wrapped_x, clampf(anchor.y, lower, maxf(lower, upper)))
	var limits := Vector2(
		maxf(0.0, (wall_size.x - definition.size.x) * 0.5 - 0.05),
		maxf(0.0, (wall_size.y - definition.size.y) * 0.5 - 0.05)
	)
	return Vector2(clampf(anchor.x, -limits.x, limits.x), clampf(anchor.y, -limits.y, limits.y))

func surface_distance(a: Vector2, b: Vector2) -> float:
	if surface_kind != SurfaceKind.PLANE:
		var circumference := TAU * cylinder_radius
		var arc_difference := absf(a.x - b.x)
		arc_difference = minf(arc_difference, circumference - arc_difference)
		return Vector2(arc_difference, a.y - b.y).length()
	return a.distance_to(b)

func screen_rect(camera: Camera3D) -> Rect2:
	var bounds := wall_size
	var center := Vector3.ZERO
	if surface_kind != SurfaceKind.PLANE:
		bounds = Vector3(cylinder_radius * 2.0, cylinder_height, cylinder_radius * 2.0)
		if surface_kind == SurfaceKind.DOME_CYLINDER:
			bounds.y += cylinder_radius
			center.y = cylinder_radius * 0.5
	var first := true
	var rect := Rect2()
	for x in [-0.5, 0.5]:
		for y in [-0.5, 0.5]:
			for z in [-0.5, 0.5]:
				var point := global_position + global_basis * (center + bounds * Vector3(x, y, z))
				if camera.is_position_behind(point):
					return Rect2()
				var projected := camera.unproject_position(point)
				if first:
					rect = Rect2(projected, Vector2.ZERO)
					first = false
				else:
					rect = rect.expand(projected)
	return rect

func set_highlight(value: bool) -> void:
	for part in outline_parts:
		part.visible = value

func register_component(component: Node3D) -> void:
	if not components.has(component):
		components.append(component)
	if preview_mode:
		component.set_direct_preview(true)
		return
	set_component_active(component, component.active)

func unregister_component(component: Node3D) -> void:
	if preview_mode:
		components.erase(component)
		return
	_detach_shapes(component)
	components.erase(component)
	_reorder()
	mark_geometry_dirty()

func set_component_active(component: Node3D, value: bool) -> void:
	if preview_mode:
		component.set_direct_preview(true)
		return
	if value:
		_attach_shapes(component)
	else:
		_detach_shapes(component)
	_reorder()
	mark_geometry_dirty()

func _attach_shapes(component: Node3D) -> void:
	for shape in component.visuals + [component.cutter]:
		if shape.get_parent() != combiner:
			combiner.add_child(shape)

func _detach_shapes(component: Node3D) -> void:
	for shape in component.visuals + [component.cutter]:
		if shape.get_parent() == combiner:
			combiner.remove_child(shape)

func _reorder() -> void:
	if combiner == null:
		return
	var index := 0
	for shape in base_shapes:
		combiner.move_child(shape, index)
		index += 1
	for component in components:
		if component.active and component.cutter.get_parent() == combiner:
			combiner.move_child(component.cutter, index)
			index += 1
	for component in components:
		if not component.active:
			continue
		for shape in component.visuals:
			if shape.get_parent() == combiner:
				combiner.move_child(shape, index)
				index += 1
