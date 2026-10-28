class_name PCGSurfaceComponent
extends Node3D

const ManifoldBuilder = preload("res://scripts/manifold_mesh_builder.gd")
const TransitionBuilder = preload("res://scripts/transition_mesh_builder.gd")

var definition: PCGComponentDefinition
var wall: Node3D
var anchor := Vector2.ZERO
var attachment_angle_degrees: float = 0.0
var transition_enabled: bool = true
var transition_thickness: float = -1.0
var transition_curvature: float = 0.65
var transition_shape: CSGMesh3D
var user_scale: float = 1.0
var neighborhood_scale: float = 1.0
var current_scale: float = 1.0
var active: bool = true
var cutter: CSGShape3D
var visuals: Array[CSGShape3D] = []
var area: Area3D
var selection_lines: MeshInstance3D
var gizmo_root: Node3D

func configure(component_definition: PCGComponentDefinition, host_wall: Node3D) -> void:
	definition = component_definition
	wall = host_wall
	attachment_angle_degrees = definition.attachment_angle_degrees
	transition_enabled = definition.transition_enabled
	transition_thickness = definition.transition_thickness
	transition_curvature = definition.transition_curvature
	name = "Component_%s" % definition.id
	_build_pick_area()
	_build_selection()
	_build_gizmos()
	_build_csg()
	_rebuild_transition_shape()
	update_transform()

func _build_pick_area() -> void:
	area = Area3D.new()
	area.name = "PickArea"
	area.collision_layer = 2
	area.collision_mask = 0
	area.monitoring = false
	area.monitorable = false
	area.set_meta("surface_component", self)
	var collision := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = Vector3(definition.size.x, definition.size.y, definition.depth + 0.24)
	collision.shape = box
	collision.position.z = definition.depth * 0.5
	area.add_child(collision)
	add_child(area)

func _build_selection() -> void:
	selection_lines = MeshInstance3D.new()
	selection_lines.name = "Selection"
	var immediate := ImmediateMesh.new()
	immediate.surface_begin(Mesh.PRIMITIVE_LINES)
	var z := definition.depth + 0.045
	if definition.shape == PCGComponentDefinition.Shape.ROUND_WINDOW:
		var radius := definition.size.x * 0.54
		for i in 64:
			var a := TAU * float(i) / 64.0
			var b := TAU * float(i + 1) / 64.0
			immediate.surface_add_vertex(Vector3(cos(a) * radius, sin(a) * radius, z))
			immediate.surface_add_vertex(Vector3(cos(b) * radius, sin(b) * radius, z))
	else:
		var half := definition.size * 0.55
		var corners := [
			Vector3(-half.x, -half.y, z), Vector3(half.x, -half.y, z),
			Vector3(half.x, half.y, z), Vector3(-half.x, half.y, z)
		]
		for i in 4:
			immediate.surface_add_vertex(corners[i])
			immediate.surface_add_vertex(corners[(i + 1) % 4])
	immediate.surface_end()
	selection_lines.mesh = immediate
	selection_lines.material_override = MaterialLibrary.unshaded(&"editor/component_selection", Color("ffe06a"))
	selection_lines.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	selection_lines.visible = false
	add_child(selection_lines)

func _build_gizmos() -> void:
	gizmo_root = Node3D.new()
	gizmo_root.name = "TransformHandles"
	gizmo_root.set_as_top_level(true)
	gizmo_root.visible = false
	add_child(gizmo_root)
	var angle_position := Vector3(0.0, definition.size.y * 0.5 + 0.42, 0.14)
	var scale_position := Vector3(definition.size.x * 0.5 + 0.42, 0.0, 0.14)
	_create_handle("angle", angle_position, Color("ff9b55"), false)
	_create_handle("scale", scale_position, Color("73e2a7"), true)
	var lines := ImmediateMesh.new()
	lines.surface_begin(Mesh.PRIMITIVE_LINES)
	lines.surface_add_vertex(Vector3(0.0, 0.0, 0.14))
	lines.surface_add_vertex(angle_position)
	lines.surface_add_vertex(Vector3(0.0, 0.0, 0.14))
	lines.surface_add_vertex(scale_position)
	var radius := angle_position.y
	for i in 36:
		var a := -PI * 0.5 + PI * float(i) / 36.0
		var b := -PI * 0.5 + PI * float(i + 1) / 36.0
		lines.surface_add_vertex(Vector3(0.0, cos(a) * radius, sin(a) * radius + 0.14))
		lines.surface_add_vertex(Vector3(0.0, cos(b) * radius, sin(b) * radius + 0.14))
	lines.surface_end()
	var line_instance := MeshInstance3D.new()
	line_instance.mesh = lines
	line_instance.material_override = _gizmo_material(Color("b8d5db"))
	line_instance.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	gizmo_root.add_child(line_instance)

func _create_handle(kind: String, local_position: Vector3, color: Color, cube: bool) -> void:
	var area_handle := Area3D.new()
	area_handle.name = "%sHandle" % kind.capitalize()
	area_handle.position = local_position
	area_handle.collision_layer = 0
	area_handle.collision_mask = 0
	area_handle.monitoring = false
	area_handle.monitorable = false
	area_handle.set_meta("attachment_handle", kind)
	area_handle.set_meta("surface_component", self)
	var collision := CollisionShape3D.new()
	var shape := SphereShape3D.new()
	shape.radius = 0.15
	collision.shape = shape
	area_handle.add_child(collision)
	gizmo_root.add_child(area_handle)
	var instance := MeshInstance3D.new()
	instance.position = local_position
	if cube:
		var mesh := BoxMesh.new()
		mesh.size = Vector3.ONE * 0.19
		instance.mesh = mesh
	else:
		var mesh := SphereMesh.new()
		mesh.radius = 0.105
		mesh.height = 0.21
		mesh.radial_segments = 16
		mesh.rings = 8
		instance.mesh = mesh
	instance.material_override = _gizmo_material(color)
	instance.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	gizmo_root.add_child(instance)

func _gizmo_material(color: Color) -> StandardMaterial3D:
	return MaterialLibrary.unshaded(StringName("editor/gizmo_%s" % color.to_html()), color)

func _build_csg() -> void:
	var opening := definition.opening_size()
	var frame_depth := definition.depth + definition.root_embed
	var frame_z := (definition.depth - definition.root_embed) * 0.5
	if definition.shape == PCGComponentDefinition.Shape.ROUND_WINDOW:
		var round_cutter := CSGCylinder3D.new()
		round_cutter.name = "OpeningCutter"
		round_cutter.operation = CSGShape3D.OPERATION_SUBTRACTION
		round_cutter.radius = opening.x * 0.5
		round_cutter.height = wall.thickness + 0.7
		round_cutter.sides = 48
		cutter = round_cutter
		_register_shape(cutter, Vector3.ZERO, Vector3(PI * 0.5, 0.0, 0.0))
		var frame := CSGMesh3D.new()
		frame.name = "RoundFrame"
		frame.operation = CSGShape3D.OPERATION_UNION
		frame.mesh = definition.custom_frame_mesh if definition.custom_frame_mesh != null else ManifoldBuilder.ring(
			definition.size.x * 0.5, opening.x * 0.5, frame_depth, 48, definition.texture_world_size, definition.root_flare
		)
		frame.material = _solid_material(definition.frame_material_id, definition.frame_profile, definition.frame_color, 0.32, 0.0, definition.texture_world_size)
		visuals.append(frame)
		_register_shape(frame, Vector3(0.0, 0.0, frame_z))
		var glass := CSGCylinder3D.new()
		glass.name = "RoundGlass"
		glass.operation = CSGShape3D.OPERATION_UNION
		glass.radius = opening.x * 0.5 + 0.025
		glass.height = 0.1
		glass.sides = 48
		glass.material = _solid_material(definition.glass_material_id, definition.glass_profile, definition.glass_color, 0.16, 0.25, definition.texture_world_size)
		visuals.append(glass)
		_register_shape(glass, Vector3(0.0, 0.0, 0.015), Vector3(PI * 0.5, 0.0, 0.0))
	else:
		var box_cutter := CSGBox3D.new()
		box_cutter.name = "OpeningCutter"
		box_cutter.operation = CSGShape3D.OPERATION_SUBTRACTION
		box_cutter.size = Vector3(opening.x, opening.y, wall.thickness + 0.7)
		cutter = box_cutter
		_register_shape(cutter, Vector3.ZERO)
		var frame_parts := [
			[Vector3(definition.size.x, definition.frame_width, frame_depth), Vector3(0.0, (definition.size.y - definition.frame_width) * 0.5, frame_z)],
			[Vector3(definition.size.x, definition.frame_width, frame_depth), Vector3(0.0, -(definition.size.y - definition.frame_width) * 0.5, frame_z)],
			[Vector3(definition.frame_width, opening.y, frame_depth), Vector3(-(definition.size.x - definition.frame_width) * 0.5, 0.0, frame_z)],
			[Vector3(definition.frame_width, opening.y, frame_depth), Vector3((definition.size.x - definition.frame_width) * 0.5, 0.0, frame_z)]
		]
		for part in frame_parts:
			var frame_box := CSGBox3D.new()
			frame_box.name = "SquareFrame"
			frame_box.operation = CSGShape3D.OPERATION_UNION
			frame_box.size = part[0]
			frame_box.material = _solid_material(definition.frame_material_id, definition.frame_profile, definition.frame_color, 0.38, 0.0, definition.texture_world_size)
			visuals.append(frame_box)
			_register_shape(frame_box, part[1])
		var square_glass := CSGBox3D.new()
		square_glass.name = "SquareGlass"
		square_glass.operation = CSGShape3D.OPERATION_UNION
		square_glass.size = Vector3(opening.x + 0.05, opening.y + 0.05, 0.1)
		square_glass.material = _solid_material(definition.glass_material_id, definition.glass_profile, definition.glass_color, 0.16, 0.25, definition.texture_world_size)
		visuals.append(square_glass)
		_register_shape(square_glass, Vector3(0.0, 0.0, 0.015))

func _register_shape(shape: CSGShape3D, local_position: Vector3, local_rotation: Vector3 = Vector3.ZERO) -> void:
	shape.set_meta("component_local", Transform3D(Basis.from_euler(local_rotation), local_position))

func effective_transition_thickness() -> float:
	if transition_thickness >= 0.0:
		return transition_thickness
	if wall.surface_kind == PCGFusedWall.SurfaceKind.PLANE:
		return 0.08
	var radius: float = wall.cylinder_radius
	var footprint := definition.footprint_radius() * maxf(current_scale, 0.1)
	var sagitta := radius - sqrt(maxf(radius * radius - footprint * footprint, 0.0))
	return clampf(0.08 + sagitta * 0.9, 0.08, 0.5)

func set_transition_enabled(value: bool) -> void:
	if transition_enabled == value:
		return
	transition_enabled = value
	_rebuild_transition_shape()

func _rebuild_transition_shape() -> void:
	if transition_shape != null:
		visuals.erase(transition_shape)
		if transition_shape.get_parent() != null:
			transition_shape.get_parent().remove_child(transition_shape)
		transition_shape.queue_free()
		transition_shape = null
	if transition_enabled:
		transition_shape = CSGMesh3D.new()
		transition_shape.name = "HostTransition"
		transition_shape.operation = CSGShape3D.OPERATION_UNION
		transition_shape.material = wall.body_material
		visuals.append(transition_shape)
		_register_shape(transition_shape, Vector3.ZERO)
		if active:
			wall.combiner.add_child(transition_shape)
	wall._reorder()
	update_transform()

func apply_scale(value: float) -> void:
	neighborhood_scale = clampf(value, 0.0, 1.0)
	current_scale = clampf(neighborhood_scale * user_scale, 0.0, 2.0)
	var should_be_active := current_scale >= definition.min_scale
	if active != should_be_active:
		active = should_be_active
		wall.set_component_active(self, active)
	area.visible = active
	area.collision_layer = 2 if active else 0
	update_transform()

func set_user_scale(value: float) -> void:
	user_scale = clampf(value, 0.1, 2.0)
	apply_scale(neighborhood_scale)

func set_selected(value: bool) -> void:
	selection_lines.visible = value and active
	gizmo_root.visible = value
	for child in gizmo_root.get_children():
		if child is Area3D:
			child.collision_layer = 4 if value else 0

func update_transform() -> void:
	if wall == null:
		return
	var tilt := Transform3D(Basis(Vector3.RIGHT, deg_to_rad(attachment_angle_degrees)), Vector3.ZERO)
	global_transform = wall.surface_transform(anchor) * tilt
	scale = Vector3.ONE * current_scale
	if selection_lines != null:
		selection_lines.visible = selection_lines.visible and active
	if gizmo_root != null:
		gizmo_root.global_transform = wall.surface_transform(anchor)
	for shape in visuals + [cutter]:
		if shape.get_parent() != null:
			shape.global_transform = global_transform * shape.get_meta("component_local") as Transform3D
	if transition_shape != null:
		transition_shape.mesh = TransitionBuilder.build(self)
	wall.mark_geometry_dirty()

static func make_preview(component_definition: PCGComponentDefinition) -> Node3D:
	var root := Node3D.new()
	root.name = "AttachmentPreview"
	var frame_material := _preview_material(StringName("preview_%s_frame" % component_definition.id), component_definition.frame_color)
	var glass_material := _preview_material(StringName("preview_%s_glass" % component_definition.id), component_definition.glass_color)
	var opening := component_definition.opening_size()
	var frame_depth := component_definition.depth + component_definition.root_embed
	var frame_z := (component_definition.depth - component_definition.root_embed) * 0.5
	if component_definition.shape == PCGComponentDefinition.Shape.ROUND_WINDOW:
		_add_preview_mesh(root, component_definition.custom_frame_mesh if component_definition.custom_frame_mesh != null else ManifoldBuilder.ring(
			component_definition.size.x * 0.5, opening.x * 0.5, frame_depth, 48, component_definition.texture_world_size, component_definition.root_flare
		), frame_material, Vector3(0.0, 0.0, frame_z))
		var glass := CylinderMesh.new()
		glass.top_radius = opening.x * 0.5
		glass.bottom_radius = opening.x * 0.5
		glass.height = 0.08
		glass.radial_segments = 48
		_add_preview_mesh(root, glass, glass_material, Vector3(0.0, 0.0, 0.02), Vector3(PI * 0.5, 0.0, 0.0))
	else:
		var parts := [
			[Vector3(component_definition.size.x, component_definition.frame_width, frame_depth), Vector3(0.0, (component_definition.size.y - component_definition.frame_width) * 0.5, frame_z)],
			[Vector3(component_definition.size.x, component_definition.frame_width, frame_depth), Vector3(0.0, -(component_definition.size.y - component_definition.frame_width) * 0.5, frame_z)],
			[Vector3(component_definition.frame_width, opening.y, frame_depth), Vector3(-(component_definition.size.x - component_definition.frame_width) * 0.5, 0.0, frame_z)],
			[Vector3(component_definition.frame_width, opening.y, frame_depth), Vector3((component_definition.size.x - component_definition.frame_width) * 0.5, 0.0, frame_z)]
		]
		for part in parts:
			var box := BoxMesh.new()
			box.size = part[0]
			_add_preview_mesh(root, box, frame_material, part[1])
		var glass_box := BoxMesh.new()
		glass_box.size = Vector3(opening.x, opening.y, 0.08)
		_add_preview_mesh(root, glass_box, glass_material, Vector3(0.0, 0.0, 0.02))
	return root

static func _add_preview_mesh(parent: Node3D, mesh: Mesh, material: Material, local_position: Vector3, local_rotation: Vector3 = Vector3.ZERO) -> void:
	var instance := MeshInstance3D.new()
	instance.mesh = mesh
	instance.material_override = material
	instance.position = local_position
	instance.rotation = local_rotation
	instance.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	parent.add_child(instance)

static func _solid_material(id: StringName, profile: PCGMaterialProfile, color: Color, roughness: float, metallic: float = 0.0, texture_world_size: float = 1.0) -> Material:
	if profile != null:
		return MaterialLibrary.profile_shader(id, preload("res://shaders/architectural_pbr.gdshader"), profile, {}, {}, &"preserve", texture_world_size)
	return MaterialLibrary.solid(id, color, roughness, metallic, &"preserve", texture_world_size)

static func _preview_material(id: StringName, color: Color) -> StandardMaterial3D:
	return MaterialLibrary.unshaded(id, Color(color, 0.42), false, true, false, BaseMaterial3D.CULL_DISABLED)
