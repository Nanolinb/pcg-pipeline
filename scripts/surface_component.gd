class_name PCGSurfaceComponent
extends Node3D

const ManifoldBuilder = preload("res://scripts/manifold_mesh_builder.gd")

var definition: PCGComponentDefinition
var wall: Node3D
var anchor := Vector2.ZERO
var attachment_angle_degrees: float = 0.0
var current_scale: float = 1.0
var active: bool = true
var cutter: CSGShape3D
var visuals: Array[CSGShape3D] = []
var area: Area3D
var selection_lines: MeshInstance3D

func configure(component_definition: PCGComponentDefinition, host_wall: Node3D) -> void:
	definition = component_definition
	wall = host_wall
	attachment_angle_degrees = definition.attachment_angle_degrees
	name = "Component_%s" % definition.id
	_build_pick_area()
	_build_selection()
	_build_csg()
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
	var material := StandardMaterial3D.new()
	material.albedo_color = Color("ffe06a")
	material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	material.no_depth_test = true
	selection_lines.material_override = material
	selection_lines.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	selection_lines.visible = false
	add_child(selection_lines)

func _build_csg() -> void:
	var opening := definition.opening_size()
	var frame_depth := definition.depth + 0.08
	var frame_z := (definition.depth - 0.08) * 0.5
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
			definition.size.x * 0.5, opening.x * 0.5, frame_depth
		)
		frame.material = _solid_material(definition.frame_color, 0.32)
		visuals.append(frame)
		_register_shape(frame, Vector3(0.0, 0.0, frame_z))
		var glass := CSGCylinder3D.new()
		glass.name = "RoundGlass"
		glass.operation = CSGShape3D.OPERATION_UNION
		glass.radius = opening.x * 0.5 + 0.025
		glass.height = 0.1
		glass.sides = 48
		glass.material = _solid_material(definition.glass_color, 0.16, 0.25)
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
			frame_box.material = _solid_material(definition.frame_color, 0.38)
			visuals.append(frame_box)
			_register_shape(frame_box, part[1])
		var square_glass := CSGBox3D.new()
		square_glass.name = "SquareGlass"
		square_glass.operation = CSGShape3D.OPERATION_UNION
		square_glass.size = Vector3(opening.x + 0.05, opening.y + 0.05, 0.1)
		square_glass.material = _solid_material(definition.glass_color, 0.16, 0.25)
		visuals.append(square_glass)
		_register_shape(square_glass, Vector3(0.0, 0.0, 0.015))

func _register_shape(shape: CSGShape3D, local_position: Vector3, local_rotation: Vector3 = Vector3.ZERO) -> void:
	shape.set_meta("component_local", Transform3D(Basis.from_euler(local_rotation), local_position))

func apply_scale(value: float) -> void:
	current_scale = clampf(value, 0.0, 1.0)
	var should_be_active := current_scale >= definition.min_scale
	if active != should_be_active:
		active = should_be_active
		wall.set_component_active(self, active)
	area.visible = active
	area.collision_layer = 2 if active else 0
	update_transform()

func set_selected(value: bool) -> void:
	selection_lines.visible = value and active

func update_transform() -> void:
	if wall == null:
		return
	var tilt := Transform3D(Basis(Vector3.RIGHT, deg_to_rad(attachment_angle_degrees)), Vector3.ZERO)
	global_transform = wall.surface_transform(anchor) * tilt
	scale = Vector3.ONE * current_scale
	if selection_lines != null:
		selection_lines.visible = selection_lines.visible and active
	for shape in visuals + [cutter]:
		if shape.get_parent() != null:
			shape.global_transform = global_transform * shape.get_meta("component_local") as Transform3D

static func make_preview(component_definition: PCGComponentDefinition) -> Node3D:
	var root := Node3D.new()
	root.name = "AttachmentPreview"
	var frame_material := _preview_material(component_definition.frame_color)
	var glass_material := _preview_material(component_definition.glass_color)
	var opening := component_definition.opening_size()
	var frame_depth := component_definition.depth + 0.08
	var frame_z := (component_definition.depth - 0.08) * 0.5
	if component_definition.shape == PCGComponentDefinition.Shape.ROUND_WINDOW:
		_add_preview_mesh(root, component_definition.custom_frame_mesh if component_definition.custom_frame_mesh != null else ManifoldBuilder.ring(
			component_definition.size.x * 0.5, opening.x * 0.5, frame_depth
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

static func _solid_material(color: Color, roughness: float, metallic: float = 0.0) -> StandardMaterial3D:
	var material := StandardMaterial3D.new()
	material.albedo_color = color
	material.roughness = roughness
	material.metallic = metallic
	return material

static func _preview_material(color: Color) -> StandardMaterial3D:
	var material := StandardMaterial3D.new()
	material.albedo_color = Color(color, 0.42)
	material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	material.cull_mode = BaseMaterial3D.CULL_DISABLED
	return material
