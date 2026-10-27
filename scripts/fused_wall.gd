class_name PCGFusedWall
extends Node3D

const SmoothMeshBuilder = preload("res://scripts/smooth_mesh_builder.gd")

enum SurfaceKind {
	PLANE,
	CYLINDER,
}

var surface_kind: SurfaceKind = SurfaceKind.PLANE
var display_name: String = "平面主体墙"
var wall_size := Vector3(6.0, 4.6, 0.36)
var cylinder_radius: float = 1.35
var cylinder_height: float = 3.8
var cylinder_depth: float = 0.7
var body_color := Color("3d777b")
var thickness: float:
	get:
		return wall_size.z if surface_kind == SurfaceKind.PLANE else cylinder_depth
var combiner: CSGCombiner3D
var body: CSGShape3D
var outline: MeshInstance3D
var render_mesh: MeshInstance3D
var solid_mesh: ArrayMesh
var wireframe_material: ShaderMaterial
var wireframe_enabled: bool = false
var render_dirty: bool = true
var components: Array = []

func _ready() -> void:
	name = display_name
	combiner = CSGCombiner3D.new()
	combiner.name = "WatertightFusion"
	add_child(combiner)
	if surface_kind == SurfaceKind.CYLINDER:
		var cylinder := CSGCylinder3D.new()
		cylinder.radius = cylinder_radius
		cylinder.height = cylinder_height
		cylinder.sides = 64
		body = cylinder
	else:
		var box := CSGBox3D.new()
		box.size = wall_size
		body = box
	body.name = "SolidSurface"
	body.operation = CSGShape3D.OPERATION_UNION
	var material := StandardMaterial3D.new()
	material.albedo_color = body_color
	material.roughness = 0.78
	body.material = material
	combiner.add_child(body)
	_build_outline()
	_build_render_mesh()

func _build_render_mesh() -> void:
	combiner.visible = false
	render_mesh = MeshInstance3D.new()
	render_mesh.name = "SmoothedFusionRender"
	add_child(render_mesh)
	wireframe_material = ShaderMaterial.new()
	wireframe_material.shader = preload("res://shaders/wireframe.gdshader")
	mark_geometry_dirty()

func mark_geometry_dirty() -> void:
	render_dirty = true

func _process(_delta: float) -> void:
	if render_dirty:
		render_dirty = false
		call_deferred("_refresh_render_mesh")

func _refresh_render_mesh() -> void:
	if not is_inside_tree() or combiner == null:
		return
	var meshes := combiner.get_meshes()
	if meshes.size() < 2 or not meshes[1] is Mesh:
		render_dirty = true
		return
	render_mesh.transform = meshes[0]
	solid_mesh = SmoothMeshBuilder.rebuild(meshes[1])
	render_mesh.mesh = SmoothMeshBuilder.build_wireframe(solid_mesh) if wireframe_enabled else solid_mesh

func set_wireframe(enabled: bool) -> void:
	wireframe_enabled = enabled
	if render_mesh != null:
		render_mesh.material_override = wireframe_material if enabled else null
		if solid_mesh != null:
			render_mesh.mesh = SmoothMeshBuilder.build_wireframe(solid_mesh) if enabled else solid_mesh

func _build_outline() -> void:
	outline = MeshInstance3D.new()
	outline.name = "AttachmentOutline"
	if surface_kind == SurfaceKind.CYLINDER:
		var cylinder := CylinderMesh.new()
		cylinder.top_radius = cylinder_radius
		cylinder.bottom_radius = cylinder_radius
		cylinder.height = cylinder_height
		cylinder.radial_segments = 64
		outline.mesh = cylinder
	else:
		var box := BoxMesh.new()
		box.size = wall_size
		outline.mesh = box
	var outline_material := ShaderMaterial.new()
	outline_material.shader = preload("res://shaders/attachment_outline.gdshader")
	outline.material_override = outline_material
	outline.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	outline.visible = false
	add_child(outline)

func surface_transform(anchor: Vector2) -> Transform3D:
	if surface_kind == SurfaceKind.CYLINDER:
		var angle := anchor.x / cylinder_radius
		var basis := Basis(Vector3.UP, angle)
		var point := Vector3(sin(angle) * cylinder_radius, anchor.y, cos(angle) * cylinder_radius)
		return global_transform * Transform3D(basis, point)
	return global_transform * Transform3D(Basis.IDENTITY, Vector3(anchor.x, anchor.y, thickness * 0.5))

func ray_anchor(origin: Vector3, direction: Vector3) -> Dictionary:
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

func clamp_anchor(anchor: Vector2, definition: PCGComponentDefinition) -> Vector2:
	if surface_kind == SurfaceKind.CYLINDER:
		var half_arc := PI * cylinder_radius
		var wrapped_x := fposmod(anchor.x + half_arc, half_arc * 2.0) - half_arc
		var height_limit := maxf(0.0, (cylinder_height - definition.size.y) * 0.5 - 0.05)
		return Vector2(wrapped_x, clampf(anchor.y, -height_limit, height_limit))
	var limits := Vector2(
		maxf(0.0, (wall_size.x - definition.size.x) * 0.5 - 0.05),
		maxf(0.0, (wall_size.y - definition.size.y) * 0.5 - 0.05)
	)
	return Vector2(clampf(anchor.x, -limits.x, limits.x), clampf(anchor.y, -limits.y, limits.y))

func surface_distance(a: Vector2, b: Vector2) -> float:
	if surface_kind == SurfaceKind.CYLINDER:
		var circumference := TAU * cylinder_radius
		var arc_difference := absf(a.x - b.x)
		arc_difference = minf(arc_difference, circumference - arc_difference)
		return Vector2(arc_difference, a.y - b.y).length()
	return a.distance_to(b)

func screen_rect(camera: Camera3D) -> Rect2:
	var bounds := wall_size if surface_kind == SurfaceKind.PLANE else Vector3(cylinder_radius * 2.0, cylinder_height, cylinder_radius * 2.0)
	var first := true
	var rect := Rect2()
	for x in [-0.5, 0.5]:
		for y in [-0.5, 0.5]:
			for z in [-0.5, 0.5]:
				var point := global_position + global_basis * (bounds * Vector3(x, y, z))
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
	if outline != null:
		outline.visible = value

func register_component(component: Node3D) -> void:
	if not components.has(component):
		components.append(component)
	set_component_active(component, component.active)

func unregister_component(component: Node3D) -> void:
	_detach_shapes(component)
	components.erase(component)
	_reorder()
	mark_geometry_dirty()

func set_component_active(component: Node3D, value: bool) -> void:
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
	combiner.move_child(body, 0)
	var index := 1
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
