extends Node3D

const ComponentDefinition = preload("res://scripts/component_definition.gd")
const ComponentCatalog = preload("res://scripts/component_catalog.gd")
const SurfaceComponent = preload("res://scripts/surface_component.gd")
const FusedWall = preload("res://scripts/fused_wall.gd")
const OverlapSolver = preload("res://scripts/overlap_solver.gd")

var camera: Camera3D
var wall: PCGFusedWall
var cylinder_host: PCGFusedWall
var hosts: Array[PCGFusedWall] = []
var component_root: Node3D
var catalog := PCGComponentCatalog.new()
var components: Array[PCGSurfaceComponent] = []
var selected: PCGSurfaceComponent
var dragging_component: bool = false
var handle_drag: String = ""
var handle_start_mouse := Vector2.ZERO
var handle_start_angle: float = 0.0
var handle_start_scale: float = 1.0
var orbiting: bool = false

var library_drag_id: StringName = &""
var ghost: Node3D
var ghost_host: PCGFusedWall
var ghost_valid: bool = false
var ghost_anchor := Vector2.ZERO

var camera_target := Vector3(0.8, 2.3, 0.0)
var camera_yaw: float = -0.28
var camera_pitch: float = 0.22
var camera_distance: float = 12.8

var status_label: Label
var stats_label: Label
var selected_name_label: Label
var selected_scale_label: Label
var selected_threshold_label: Label
var selected_anchor_label: Label
var selected_state_label: Label
var attachment_angle_spin: SpinBox
var wireframe_button: Button

func _ready() -> void:
	_build_environment()
	wall = FusedWall.new()
	wall.position = Vector3(0.0, 2.5, 0.0)
	add_child(wall)
	cylinder_host = FusedWall.new()
	cylinder_host.surface_kind = PCGFusedWall.SurfaceKind.CYLINDER
	cylinder_host.display_name = "圆柱主体"
	cylinder_host.cylinder_radius = 1.2
	cylinder_host.cylinder_height = 3.8
	cylinder_host.body_color = Color("93654f")
	cylinder_host.position = Vector3(4.35, 1.9, -0.4)
	add_child(cylinder_host)
	hosts.assign([wall, cylinder_host])
	component_root = Node3D.new()
	component_root.name = "PlacedComponents"
	add_child(component_root)
	_build_camera()
	catalog.load_from("res://assets/components")
	_build_ui()
	_update_camera()
	_update_inspector()
	if "--smoke-test" in OS.get_cmdline_user_args():
		call_deferred("_run_smoke_test")

func _build_environment() -> void:
	var world_environment := WorldEnvironment.new()
	var environment := Environment.new()
	environment.background_mode = Environment.BG_COLOR
	environment.background_color = Color("16252e")
	environment.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	environment.ambient_light_color = Color("b8d8df")
	environment.ambient_light_energy = 0.42
	environment.tonemap_mode = Environment.TONE_MAPPER_FILMIC
	world_environment.environment = environment
	add_child(world_environment)
	var sun := DirectionalLight3D.new()
	sun.rotation_degrees = Vector3(-48.0, -28.0, 0.0)
	sun.light_color = Color("ffe0b5")
	sun.light_energy = 0.85
	sun.shadow_enabled = true
	add_child(sun)
	var fill := DirectionalLight3D.new()
	fill.rotation_degrees = Vector3(-25.0, 145.0, 0.0)
	fill.light_color = Color("81b9e8")
	fill.light_energy = 0.25
	add_child(fill)
	var ground := MeshInstance3D.new()
	ground.name = "Ground"
	var ground_mesh := BoxMesh.new()
	ground_mesh.size = Vector3(16.0, 0.25, 12.0)
	ground.mesh = ground_mesh
	ground.position = Vector3(0.0, -0.15, 0.0)
	var ground_material := StandardMaterial3D.new()
	ground_material.albedo_color = Color("293b43")
	ground_material.roughness = 0.92
	ground.material_override = ground_material
	add_child(ground)

func _build_camera() -> void:
	camera = Camera3D.new()
	camera.name = "OrbitCamera"
	camera.fov = 46.0
	camera.near = 0.05
	camera.far = 120.0
	camera.current = true
	add_child(camera)

func _build_ui() -> void:
	var canvas := CanvasLayer.new()
	add_child(canvas)
	var title_panel := PanelContainer.new()
	title_panel.set_anchors_preset(Control.PRESET_TOP_LEFT)
	title_panel.offset_left = 18.0
	title_panel.offset_top = 16.0
	title_panel.offset_right = 850.0
	title_panel.offset_bottom = 122.0
	canvas.add_child(title_panel)
	var title_box := VBoxContainer.new()
	title_panel.add_child(title_box)
	var title := Label.new()
	title.text = "表面组件 PCG · 吸附 / 联动 / 实体融合"
	title.add_theme_font_size_override("font_size", 22)
	title_box.add_child(title)
	status_label = Label.new()
	status_label.text = "从左侧组件库拖入窗户；可吸附到平面墙或右侧圆柱。"
	status_label.add_theme_color_override("font_color", Color("c2dce5"))
	title_box.add_child(status_label)
	stats_label = Label.new()
	stats_label.text = "库拖放：按住资产卡片拖入视口 · 编辑：左键拖动 · 环绕：右键 · 缩放：滚轮"
	stats_label.add_theme_color_override("font_color", Color("8faab5"))
	title_box.add_child(stats_label)

	var library_panel := PanelContainer.new()
	library_panel.set_anchors_preset(Control.PRESET_LEFT_WIDE)
	library_panel.offset_left = 18.0
	library_panel.offset_right = 282.0
	library_panel.offset_top = 140.0
	library_panel.offset_bottom = -18.0
	library_panel.add_theme_font_size_override("font_size", 15)
	canvas.add_child(library_panel)
	var library_margin := MarginContainer.new()
	library_margin.add_theme_constant_override("margin_left", 10)
	library_margin.add_theme_constant_override("margin_right", 10)
	library_panel.add_child(library_margin)
	var library_scroll := ScrollContainer.new()
	library_margin.add_child(library_scroll)
	var library_box := VBoxContainer.new()
	library_box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	library_box.add_theme_constant_override("separation", 10)
	library_scroll.add_child(library_box)
	_add_heading(library_box, "组件资产库")
	_add_hint(library_box, "按住卡片并拖到主体上\n预览与主体交叠时轮廓高亮\n松开鼠标才会吸附放置")
	for definition in catalog.definitions:
		var card := Button.new()
		card.text = "%s\n%s  %.2f × %.2f m\n消失阈值  %d%%" % [
			definition.display_name,
			"圆形" if definition.shape == ComponentDefinition.Shape.ROUND_WINDOW else "方形",
			definition.size.x, definition.size.y, roundi(definition.min_scale * 100.0)
		]
		card.custom_minimum_size = Vector2(0.0, 92.0)
		card.focus_mode = Control.FOCUS_NONE
		card.button_down.connect(_begin_library_drag.bind(definition.id))
		library_box.add_child(card)
	for error in catalog.errors:
		_add_hint(library_box, error)
	_add_heading(library_box, "操作")
	_add_hint(library_box, "1. 拖入圆窗与下方方窗\n2. 拖动圆窗向方窗靠近\n3. 方窗缩小，低于阈值消失\n4. 移开圆窗，方窗恢复")
	var clear_button := Button.new()
	clear_button.text = "清空全部组件"
	clear_button.pressed.connect(_clear_components)
	library_box.add_child(clear_button)
	var reset_button := Button.new()
	reset_button.text = "重置视角 (F)"
	reset_button.pressed.connect(_reset_camera)
	library_box.add_child(reset_button)

	var inspector_panel := PanelContainer.new()
	inspector_panel.set_anchors_preset(Control.PRESET_RIGHT_WIDE)
	inspector_panel.offset_left = -318.0
	inspector_panel.offset_right = -18.0
	inspector_panel.offset_top = 140.0
	inspector_panel.offset_bottom = -18.0
	inspector_panel.add_theme_font_size_override("font_size", 15)
	canvas.add_child(inspector_panel)
	var inspector_margin := MarginContainer.new()
	inspector_margin.add_theme_constant_override("margin_left", 10)
	inspector_margin.add_theme_constant_override("margin_right", 10)
	inspector_panel.add_child(inspector_margin)
	var inspector := VBoxContainer.new()
	inspector.add_theme_constant_override("separation", 10)
	inspector_margin.add_child(inspector)
	_add_heading(inspector, "选中组件")
	selected_name_label = _inspector_value(inspector, "未选择")
	var angle_row := HBoxContainer.new()
	inspector.add_child(angle_row)
	var angle_label := Label.new()
	angle_label.text = "法线倾角"
	angle_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	angle_row.add_child(angle_label)
	attachment_angle_spin = SpinBox.new()
	attachment_angle_spin.min_value = -90.0
	attachment_angle_spin.max_value = 90.0
	attachment_angle_spin.step = 1.0
	attachment_angle_spin.suffix = "°"
	attachment_angle_spin.editable = false
	attachment_angle_spin.value_changed.connect(_on_attachment_angle_changed)
	angle_row.add_child(attachment_angle_spin)
	selected_scale_label = _inspector_value(inspector, "")
	selected_threshold_label = _inspector_value(inspector, "")
	selected_anchor_label = _inspector_value(inspector, "")
	selected_state_label = _inspector_value(inspector, "")
	_add_hint(inspector, "拖动已放置组件时仍保持吸附。\n橙色球：上下拖动调整法线倾角。\n绿色方块：左右拖动等比缩放。\n0° 表示完全遵循主体表面法线。")
	_add_heading(inspector, "融合方式")
	_add_hint(inspector, "主体与组件采用封闭实体 CSG。\n先执行全部开洞差集，再执行窗框\n与玻璃并集。组件消失时移除开洞，\n主体墙面会真实恢复。")
	wireframe_button = Button.new()
	wireframe_button.text = "水密线框：关 (G)"
	wireframe_button.toggle_mode = true
	wireframe_button.focus_mode = Control.FOCUS_NONE
	wireframe_button.toggled.connect(_toggle_wireframe)
	inspector.add_child(wireframe_button)
	_add_hint(inspector, "线框模式显示实际三角网格，\n用于检查开洞与融合边界。")
	_add_heading(inspector, "快捷键")
	_add_hint(inspector, "Delete  删除选中组件\nEsc  取消拖放 / 选择\nF  重置视角\nG  切换水密线框")

func _add_heading(parent: VBoxContainer, text: String) -> void:
	var separator := HSeparator.new()
	parent.add_child(separator)
	var label := Label.new()
	label.text = text
	label.add_theme_font_size_override("font_size", 20)
	parent.add_child(label)

func _add_hint(parent: VBoxContainer, text: String) -> void:
	var label := Label.new()
	label.text = text
	label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	label.add_theme_font_size_override("font_size", 14)
	label.add_theme_color_override("font_color", Color("91aab4"))
	parent.add_child(label)

func _inspector_value(parent: VBoxContainer, text: String) -> Label:
	var label := Label.new()
	label.text = text
	label.add_theme_color_override("font_color", Color("d5e5e9"))
	parent.add_child(label)
	return label

func _input(event: InputEvent) -> void:
	if not library_drag_id.is_empty():
		if event is InputEventMouseMotion:
			_update_library_drag(event.position)
			get_viewport().set_input_as_handled()
		elif event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT and not event.pressed:
			_finish_library_drag()
			get_viewport().set_input_as_handled()
		elif event is InputEventKey and event.pressed and event.keycode == KEY_ESCAPE:
			_cancel_library_drag()
			status_label.text = "已取消资产拖放。"
			get_viewport().set_input_as_handled()
		return
	if not handle_drag.is_empty():
		if event is InputEventMouseMotion and selected != null:
			_drag_transform_handle(event.position)
			get_viewport().set_input_as_handled()
		elif event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT and not event.pressed:
			handle_drag = ""
			status_label.text = "组件变换已更新。"
			get_viewport().set_input_as_handled()
		return
	if dragging_component:
		if event is InputEventMouseMotion and selected != null:
			_drag_selected(event.position)
			get_viewport().set_input_as_handled()
		elif event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT and not event.pressed:
			dragging_component = false
			status_label.text = "组件位置已更新；邻域尺寸已重新求解。"
			get_viewport().set_input_as_handled()

func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventMouseButton:
		if event.button_index == MOUSE_BUTTON_RIGHT:
			orbiting = event.pressed
		elif event.button_index == MOUSE_BUTTON_WHEEL_UP and event.pressed:
			camera_distance = maxf(4.0, camera_distance * 0.9)
			_update_camera()
		elif event.button_index == MOUSE_BUTTON_WHEEL_DOWN and event.pressed:
			camera_distance = minf(28.0, camera_distance * 1.1)
			_update_camera()
		elif event.button_index == MOUSE_BUTTON_LEFT:
			if event.pressed:
				_select_or_drag(event.position)
			elif dragging_component:
				dragging_component = false
				status_label.text = "组件位置已更新；邻域尺寸已重新求解。"
	elif event is InputEventMouseMotion:
		if orbiting:
			camera_yaw -= event.relative.x * 0.006
			camera_pitch = clampf(camera_pitch + event.relative.y * 0.005, -0.08, 1.2)
			_update_camera()
		elif dragging_component and selected != null:
			_drag_selected(event.position)
	elif event is InputEventKey and event.pressed and not event.echo:
		if event.keycode == KEY_F:
			_reset_camera()
		elif event.keycode == KEY_ESCAPE:
			_select_component(null)
			status_label.text = "已取消选择。"
		elif event.keycode == KEY_DELETE:
			_delete_selected()
		elif event.keycode == KEY_G:
			wireframe_button.button_pressed = not wireframe_button.button_pressed

func _notification(what: int) -> void:
	if what == NOTIFICATION_WM_WINDOW_FOCUS_OUT and not library_drag_id.is_empty():
		_cancel_library_drag()

func _begin_library_drag(id: StringName) -> void:
	var definition := catalog.get_definition(id)
	if definition == null:
		status_label.text = "资产无法加载：%s" % id
		return
	_cancel_library_drag()
	_select_component(null)
	library_drag_id = id
	ghost = SurfaceComponent.make_preview(definition)
	add_child(ghost)
	ghost_valid = false
	status_label.text = "正在拖放「%s」· 与主体交叠可查看吸附高亮" % definition.display_name

func _update_library_drag(screen_position: Vector2) -> void:
	if ghost == null:
		return
	var definition := catalog.get_definition(library_drag_id)
	if definition == null:
		return
	var origin := camera.project_ray_origin(screen_position)
	var direction := camera.project_ray_normal(screen_position)
	var nearest := INF
	var hit: Dictionary = {}
	ghost_host = null
	for host in hosts:
		var candidate := host.ray_anchor(origin, direction)
		if candidate.is_empty():
			continue
		var distance := camera.global_position.distance_to(candidate["position"])
		if distance < nearest:
			nearest = distance
			hit = candidate
			ghost_host = host
	ghost_valid = not hit.is_empty()
	if ghost_valid:
		ghost_anchor = ghost_host.clamp_anchor(hit["anchor"], definition)
		var tilt := Transform3D(Basis(Vector3.RIGHT, deg_to_rad(definition.attachment_angle_degrees)), Vector3.ZERO)
		ghost.global_transform = ghost_host.surface_transform(ghost_anchor) * tilt
	else:
		var view_plane := Plane(-camera.global_basis.z.normalized(), camera_target)
		var point: Variant = view_plane.intersects_ray(origin, direction)
		if point != null:
			ghost.global_transform = Transform3D(camera.global_basis, point)
	var any_overlap := false
	var ghost_rect := _definition_screen_rect(definition, ghost.global_transform)
	for host in hosts:
		var overlaps := ghost_rect.intersects(host.screen_rect(camera))
		host.set_highlight(overlaps)
		any_overlap = any_overlap or overlaps
	if ghost_valid:
		status_label.text = "已吸附到「%s」· 松开左键放置%s" % [ghost_host.display_name, definition.display_name]
	elif any_overlap:
		status_label.text = "主体轮廓已高亮 · 将预览移到可吸附表面内"
	else:
		status_label.text = "将组件预览拖到平面墙或圆柱主体上"

func _finish_library_drag() -> void:
	if library_drag_id.is_empty():
		return
	var id := library_drag_id
	var valid := ghost_valid
	var anchor := ghost_anchor
	var host := ghost_host
	_cancel_library_drag()
	if valid:
		_place_component(id, anchor, host)
	else:
		status_label.text = "未命中可吸附主体，本次拖放已取消。"

func _cancel_library_drag() -> void:
	library_drag_id = &""
	ghost_valid = false
	ghost_host = null
	if ghost != null:
		remove_child(ghost)
		ghost.queue_free()
		ghost = null
	for host in hosts:
		host.set_highlight(false)

func _place_component(id: StringName, anchor: Vector2, host: PCGFusedWall = null) -> PCGSurfaceComponent:
	var definition := catalog.get_definition(id)
	if definition == null:
		return null
	if host == null:
		host = wall
	var component := SurfaceComponent.new()
	component_root.add_child(component)
	component.configure(definition, host)
	component.anchor = host.clamp_anchor(anchor, definition)
	component.update_transform()
	components.append(component)
	host.register_component(component)
	component.update_transform()
	_solve_neighborhood()
	_select_component(component)
	status_label.text = "已放置到「%s」· 可继续拖入组件或拖动调整" % host.display_name
	return component

func _select_or_drag(screen_position: Vector2) -> void:
	var handle := _pick_transform_handle(screen_position)
	if not handle.is_empty() and selected != null:
		handle_drag = handle
		handle_start_mouse = screen_position
		handle_start_angle = selected.attachment_angle_degrees
		handle_start_scale = selected.user_scale
		dragging_component = false
		status_label.text = "拖动角度手柄：上下调整法线倾角" if handle == "angle" else "拖动缩放手柄：左右调整整体尺寸"
		return
	var component := _pick_component(screen_position)
	_select_component(component)
	if component != null:
		dragging_component = true
		status_label.text = "正在拖动「%s」· 表面吸附保持开启" % component.definition.display_name

func _pick_transform_handle(screen_position: Vector2) -> String:
	var origin := camera.project_ray_origin(screen_position)
	var direction := camera.project_ray_normal(screen_position)
	var query := PhysicsRayQueryParameters3D.create(origin, origin + direction * 100.0)
	query.collide_with_areas = true
	query.collide_with_bodies = false
	query.collision_mask = 4
	var hit := get_world_3d().direct_space_state.intersect_ray(query)
	if hit.is_empty():
		return ""
	return hit["collider"].get_meta("attachment_handle", "") as String

func _drag_transform_handle(screen_position: Vector2) -> void:
	var delta := screen_position - handle_start_mouse
	if handle_drag == "angle":
		_on_attachment_angle_changed(clampf(handle_start_angle - delta.y * 0.4, -90.0, 90.0))
	elif handle_drag == "scale":
		selected.set_user_scale(handle_start_scale + delta.x * 0.005)
		_solve_neighborhood(selected)

func _pick_component(screen_position: Vector2) -> PCGSurfaceComponent:
	var origin := camera.project_ray_origin(screen_position)
	var direction := camera.project_ray_normal(screen_position)
	var query := PhysicsRayQueryParameters3D.create(origin, origin + direction * 100.0)
	query.collide_with_areas = true
	query.collide_with_bodies = false
	query.collision_mask = 2
	var hit := get_world_3d().direct_space_state.intersect_ray(query)
	if hit.is_empty():
		return null
	return hit["collider"].get_meta("surface_component") as PCGSurfaceComponent

func _drag_selected(screen_position: Vector2) -> void:
	var origin := camera.project_ray_origin(screen_position)
	var direction := camera.project_ray_normal(screen_position)
	var hit: Dictionary = selected.wall.ray_anchor(origin, direction)
	if hit.is_empty():
		return
	_move_component(selected, hit["anchor"])

func _move_component(component: PCGSurfaceComponent, anchor: Vector2) -> void:
	component.anchor = component.wall.clamp_anchor(anchor, component.definition)
	component.update_transform()
	_solve_neighborhood(component)

func _solve_neighborhood(dragged: PCGSurfaceComponent = null) -> void:
	var scales := OverlapSolver.solve(components, dragged)
	for component in components:
		component.apply_scale(scales[component.get_instance_id()])
		if component == selected:
			component.set_selected(true)
	_update_inspector()

func _select_component(component: PCGSurfaceComponent) -> void:
	if selected != null and is_instance_valid(selected):
		selected.set_selected(false)
	selected = component
	if selected != null:
		selected.set_selected(true)
	_update_inspector()

func _update_inspector() -> void:
	if selected_name_label == null:
		return
	if selected == null or not is_instance_valid(selected):
		selected_name_label.text = "未选择"
		selected_scale_label.text = "从库中拖放，或点击已有组件"
		selected_threshold_label.text = ""
		selected_anchor_label.text = ""
		selected_state_label.text = ""
		attachment_angle_spin.editable = false
		attachment_angle_spin.set_value_no_signal(0.0)
		return
	selected_name_label.text = "%s · %s" % [selected.definition.display_name, selected.wall.display_name]
	selected_scale_label.text = "当前尺寸：%d%%" % roundi(selected.current_scale * 100.0)
	selected_threshold_label.text = "资产消失阈值：%d%%" % roundi(selected.definition.min_scale * 100.0)
	selected_anchor_label.text = "表面锚点：%.2f, %.2f m" % [selected.anchor.x, selected.anchor.y]
	selected_state_label.text = "状态：%s · 始终吸附" % ("已融合" if selected.active else "已消失 / 主体恢复")
	selected_state_label.add_theme_color_override("font_color", Color("83e0b5") if selected.active else Color("ff9d79"))
	attachment_angle_spin.editable = true
	attachment_angle_spin.set_value_no_signal(selected.attachment_angle_degrees)

func _on_attachment_angle_changed(value: float) -> void:
	if selected == null:
		return
	selected.attachment_angle_degrees = value
	selected.update_transform()
	status_label.text = "法线倾角已设为 %.0f°；0° 表示完全遵循主体表面法线。" % value

func _delete_selected() -> void:
	if selected == null:
		return
	var component := selected
	_select_component(null)
	components.erase(component)
	component.wall.unregister_component(component)
	component.queue_free()
	_solve_neighborhood()
	status_label.text = "组件已删除，邻域与主体已更新。"

func _clear_components() -> void:
	_cancel_library_drag()
	_select_component(null)
	for component in components:
		component.wall.unregister_component(component)
		component.queue_free()
	components.clear()
	status_label.text = "已恢复两个空白主体；从左侧资产库拖入组件。"

func _definition_screen_rect(definition: PCGComponentDefinition, transform: Transform3D) -> Rect2:
	var first := true
	var rect := Rect2()
	for x in [-0.5, 0.5]:
		for y in [-0.5, 0.5]:
			for z in [0.0, definition.depth]:
				var point := transform * Vector3(definition.size.x * x, definition.size.y * y, z)
				if camera.is_position_behind(point):
					return Rect2()
				var projected := camera.unproject_position(point)
				if first:
					rect = Rect2(projected, Vector2.ZERO)
					first = false
				else:
					rect = rect.expand(projected)
	return rect

func _update_camera() -> void:
	if camera == null:
		return
	var offset := Vector3(
		cos(camera_pitch) * sin(camera_yaw),
		sin(camera_pitch),
		cos(camera_pitch) * cos(camera_yaw)
	) * camera_distance
	camera.position = camera_target + offset
	camera.look_at(camera_target, Vector3.UP)

func _reset_camera() -> void:
	camera_target = Vector3(0.8, 2.3, 0.0)
	camera_yaw = -0.28
	camera_pitch = 0.22
	camera_distance = 12.8
	_update_camera()

func _toggle_wireframe(enabled: bool) -> void:
	for host in hosts:
		host.set_wireframe(enabled)
	wireframe_button.text = "水密线框：%s (G)" % ("开" if enabled else "关")
	status_label.text = "已切换为最终融合网格线框；再次按 G 恢复实体显示。" if enabled else "已恢复实体材质显示。"

func _screen_for_anchor(anchor: Vector2) -> Vector2:
	return camera.unproject_position(wall.surface_transform(anchor).origin)

func _run_smoke_test() -> void:
	await get_tree().process_frame
	await get_tree().physics_frame
	var failures := PackedStringArray()
	_smoke_check(catalog.definitions.size() == 2, "应加载两份组件资产", failures)
	_begin_library_drag(&"round_window")
	_update_library_drag(_screen_for_anchor(Vector2(0.0, 0.8)))
	_smoke_check(ghost_valid, "库预览应命中主体", failures)
	_smoke_check(wall.outline.visible, "视口交叠应高亮主体轮廓", failures)
	_finish_library_drag()
	_smoke_check(components.size() == 1, "有效松开应创建一个组件", failures)
	_smoke_check(not wall.outline.visible, "拖放结束应清除高亮", failures)
	var round_window := components[0]
	_begin_library_drag(&"square_window")
	_update_library_drag(_screen_for_anchor(Vector2(0.0, -0.8)))
	_finish_library_drag()
	_smoke_check(components.size() == 2, "第二次库拖放应创建方窗", failures)
	var square_window := components[1]
	var drag_target := square_window.anchor + Vector2(0.0, 1.15)
	if DisplayServer.get_name() == "headless":
		_move_component(round_window, drag_target)
	else:
		var drag_start := _screen_for_anchor(round_window.anchor)
		var drag_end := _screen_for_anchor(drag_target)
		var press := InputEventMouseButton.new()
		press.button_index = MOUSE_BUTTON_LEFT
		press.pressed = true
		press.position = drag_start
		press.global_position = drag_start
		Input.parse_input_event(press)
		await get_tree().process_frame
		var motion := InputEventMouseMotion.new()
		motion.position = drag_end
		motion.global_position = drag_end
		motion.relative = drag_end - drag_start
		motion.button_mask = MOUSE_BUTTON_MASK_LEFT
		Input.parse_input_event(motion)
		await get_tree().process_frame
		var release := InputEventMouseButton.new()
		release.button_index = MOUSE_BUTTON_LEFT
		release.pressed = false
		release.position = drag_end
		release.global_position = drag_end
		Input.parse_input_event(release)
		await get_tree().process_frame
		_smoke_check(round_window.anchor.distance_to(drag_target) < 0.01, "真实输入事件应拖动已放置组件", failures)
	_smoke_check(square_window.current_scale < 1.0 and square_window.active, "重叠应使方窗缩小但保持激活", failures)
	_move_component(round_window, square_window.anchor + Vector2(0.0, 0.6))
	_smoke_check(not square_window.active, "低于阈值应使方窗消失", failures)
	_smoke_check(square_window.cutter.get_parent() == null, "消失组件应移除 CSG 开洞体", failures)
	_move_component(round_window, Vector2(0.0, 1.5))
	_smoke_check(square_window.active and is_equal_approx(square_window.current_scale, 1.0), "移开后方窗应完整恢复", failures)
	var count := components.size()
	_begin_library_drag(&"round_window")
	_update_library_drag(Vector2(4.0, 4.0))
	_smoke_check(not ghost_valid and not wall.outline.visible, "空白处预览不应吸附或高亮", failures)
	_finish_library_drag()
	_smoke_check(components.size() == count, "无效松开不应创建组件", failures)
	await get_tree().process_frame
	await get_tree().process_frame
	var fused_meshes := wall.combiner.get_meshes()
	_smoke_check(fused_meshes.size() == 2 and fused_meshes[1] is Mesh, "CSG 应输出实际融合网格", failures)
	_smoke_check(hosts.size() == 2, "应存在平面与圆柱两个吸附主体", failures)
	var cylinder_anchor := Vector2(0.0, 0.6)
	var cylinder_transform := cylinder_host.surface_transform(cylinder_anchor)
	var cylinder_hit := cylinder_host.ray_anchor(
		cylinder_transform.origin + cylinder_transform.basis.z * 3.0,
		-cylinder_transform.basis.z.normalized()
	)
	_smoke_check(not cylinder_hit.is_empty() and cylinder_hit["anchor"].distance_to(cylinder_anchor) < 0.01, "圆柱射线应返回正确弧长与高度", failures)
	_begin_library_drag(&"round_window")
	_update_library_drag(camera.unproject_position(cylinder_transform.origin))
	_smoke_check(ghost_valid and ghost_host == cylinder_host, "库拖放应命中圆柱主体", failures)
	_smoke_check(cylinder_host.outline.visible, "圆柱拖放交叠应显示轮廓", failures)
	_finish_library_drag()
	var cylinder_round: PCGSurfaceComponent = components[-1]
	_smoke_check(cylinder_round.wall == cylinder_host and cylinder_host.combiner.get_meshes().size() == 2, "圆柱应生成实际 CSG 融合网格", failures)
	_move_component(cylinder_round, square_window.anchor)
	_smoke_check(is_equal_approx(square_window.current_scale, 1.0) and is_equal_approx(cylinder_round.current_scale, 1.0), "不同主体的组件不应互相缩放", failures)
	var curved_anchor := Vector2(1.0, 0.4)
	_move_component(cylinder_round, curved_anchor)
	var angle := curved_anchor.x / cylinder_host.cylinder_radius
	var expected_normal := (cylinder_host.global_basis * Vector3(sin(angle), 0.0, cos(angle))).normalized()
	_smoke_check(cylinder_round.global_basis.z.normalized().dot(expected_normal) > 0.999, "圆柱拖动后组件应沿径向法线定向", failures)
	_select_component(cylinder_round)
	_on_attachment_angle_changed(25.0)
	var tilted_normal := (cylinder_host.surface_transform(curved_anchor) * Transform3D(Basis(Vector3.RIGHT, deg_to_rad(25.0)), Vector3.ZERO)).basis.z.normalized()
	_smoke_check(cylinder_round.global_basis.z.normalized().dot(tilted_normal) > 0.999, "法线倾角应旋转完整组件", failures)
	_on_attachment_angle_changed(0.0)
	cylinder_round.set_user_scale(1.5)
	_solve_neighborhood(cylinder_round)
	_smoke_check(is_equal_approx(cylinder_round.current_scale, 1.5), "用户缩放应与邻域缩放相乘", failures)
	cylinder_round.set_user_scale(1.0)
	_solve_neighborhood(cylinder_round)
	if DisplayServer.get_name() != "headless":
		await get_tree().physics_frame
		var angle_handle_position := Vector3(0.0, cylinder_round.definition.size.y * 0.5 + 0.42, 0.14)
		var angle_handle_screen := camera.unproject_position(cylinder_round.gizmo_root.to_global(angle_handle_position))
		_smoke_check(_pick_transform_handle(angle_handle_screen) == "angle", "橙色手柄应可拾取", failures)
		await _smoke_mouse_drag(angle_handle_screen, angle_handle_screen + Vector2(0.0, -50.0))
		_smoke_check(absf(cylinder_round.attachment_angle_degrees - 20.0) < 0.01, "角度手柄应驱动法线倾角", failures)
		var scale_handle_position := Vector3(cylinder_round.definition.size.x * 0.5 + 0.42, 0.0, 0.14)
		var scale_handle_screen := camera.unproject_position(cylinder_round.gizmo_root.to_global(scale_handle_position))
		_smoke_check(_pick_transform_handle(scale_handle_screen) == "scale", "绿色手柄应可拾取", failures)
		await _smoke_mouse_drag(scale_handle_screen, scale_handle_screen + Vector2(100.0, 0.0))
		_smoke_check(absf(cylinder_round.user_scale - 1.5) < 0.01, "缩放手柄应驱动用户等比缩放", failures)
		_on_attachment_angle_changed(0.0)
		cylinder_round.set_user_scale(1.0)
		_solve_neighborhood(cylinder_round)
	await get_tree().process_frame
	await get_tree().process_frame
	for host in hosts:
		_smoke_check(host.render_mesh.mesh != null, "最终平滑渲染网格应已生成", failures)
		if host.render_mesh.mesh != null:
			var normals_valid := true
			for surface in host.render_mesh.mesh.get_surface_count():
				var arrays := host.render_mesh.mesh.surface_get_arrays(surface)
				var normals: PackedVector3Array = arrays[Mesh.ARRAY_NORMAL] if arrays[Mesh.ARRAY_NORMAL] != null else PackedVector3Array()
				if normals.is_empty():
					normals_valid = false
				for normal in normals:
					if absf(normal.length() - 1.0) > 0.001:
						normals_valid = false
			_smoke_check(normals_valid, "最终网格应包含有效单位法线", failures)
	_toggle_wireframe(true)
	_smoke_check(wall.render_mesh.material_override == wall.wireframe_material and cylinder_host.render_mesh.material_override == cylinder_host.wireframe_material, "线框开关应作用于两个最终渲染网格", failures)
	_toggle_wireframe(false)
	_smoke_check(wall.render_mesh.material_override == null and cylinder_host.render_mesh.material_override == null, "关闭线框应恢复表面材质", failures)
	if failures.is_empty():
		print("PCG_SMOKE_TEST_PASS: dual hosts, smoothed CSG render, visible wireframe material, snapping, handles, isolated shrink")
		get_tree().quit(0)
	else:
		for failure in failures:
			push_error("SMOKE: " + failure)
		get_tree().quit(1)

func _smoke_mouse_drag(start: Vector2, finish: Vector2) -> void:
	var press := InputEventMouseButton.new()
	press.button_index = MOUSE_BUTTON_LEFT
	press.pressed = true
	press.position = start
	press.global_position = start
	Input.parse_input_event(press)
	await get_tree().process_frame
	var motion := InputEventMouseMotion.new()
	motion.position = finish
	motion.global_position = finish
	motion.relative = finish - start
	motion.button_mask = MOUSE_BUTTON_MASK_LEFT
	Input.parse_input_event(motion)
	await get_tree().process_frame
	var release := InputEventMouseButton.new()
	release.button_index = MOUSE_BUTTON_LEFT
	release.pressed = false
	release.position = finish
	release.global_position = finish
	Input.parse_input_event(release)
	await get_tree().process_frame

func _smoke_check(condition: bool, message: String, failures: PackedStringArray) -> void:
	if not condition:
		failures.append(message)
