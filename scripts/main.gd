extends Node3D

const ComponentDefinition = preload("res://scripts/component_definition.gd")
const ComponentCatalog = preload("res://scripts/component_catalog.gd")
const SurfaceComponent = preload("res://scripts/surface_component.gd")
const FusedWall = preload("res://scripts/fused_wall.gd")
const OverlapSolver = preload("res://scripts/overlap_solver.gd")
const SmokeTestRunner = preload("res://scripts/tests/smoke_test_runner.gd")

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
var transition_toggle: CheckButton
var transition_thickness_spin: SpinBox
var transition_curvature_spin: SpinBox
var transition_density_option: OptionButton
var transition_lod_option: OptionButton
var wireframe_button: Button
var deferred_fusion_toggle: CheckButton
var merge_all_button: Button
var merge_selected_button: Button
var frame_slot_panel: PCGTextureSlotPanel
var glass_slot_panel: PCGTextureSlotPanel

func _ready() -> void:
	_build_environment()
	wall = FusedWall.new()
	wall.position = Vector3(0.0, 2.5, 0.0)
	add_child(wall)
	cylinder_host = FusedWall.new()
	cylinder_host.surface_kind = PCGFusedWall.SurfaceKind.DOME_CYLINDER
	cylinder_host.display_name = "半球圆柱主体"
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
	elif "--visual-check" in OS.get_cmdline_user_args():
		call_deferred("_run_visual_check")

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
	ground.material_override = MaterialLibrary.solid(&"environment/ground", Color("293b43"), 0.92)
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
	status_label.text = "从左侧拖入窗户；可吸附到平面墙或右侧半球圆柱，并拖过赤道。"
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
			["圆形", "方形", "拱形"][definition.shape],
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
	var inspector_scroll := ScrollContainer.new()
	inspector_margin.add_child(inspector_scroll)
	var inspector := VBoxContainer.new()
	inspector.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	inspector.add_theme_constant_override("separation", 10)
	inspector_scroll.add_child(inspector)
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
	transition_toggle = CheckButton.new()
	transition_toggle.text = "主体包裹过渡"
	transition_toggle.disabled = true
	transition_toggle.toggled.connect(_on_transition_toggled)
	inspector.add_child(transition_toggle)
	var thickness_row := HBoxContainer.new()
	inspector.add_child(thickness_row)
	var thickness_label := Label.new()
	thickness_label.text = "过渡厚度"
	thickness_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	thickness_row.add_child(thickness_label)
	transition_thickness_spin = SpinBox.new()
	transition_thickness_spin.min_value = 0.02
	transition_thickness_spin.max_value = 1.0
	transition_thickness_spin.step = 0.01
	transition_thickness_spin.suffix = "m"
	transition_thickness_spin.editable = false
	transition_thickness_spin.value_changed.connect(_on_transition_thickness_changed)
	thickness_row.add_child(transition_thickness_spin)
	var curvature_row := HBoxContainer.new()
	inspector.add_child(curvature_row)
	var curvature_label := Label.new()
	curvature_label.text = "过渡弧度"
	curvature_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	curvature_row.add_child(curvature_label)
	transition_curvature_spin = SpinBox.new()
	transition_curvature_spin.min_value = -1.0
	transition_curvature_spin.max_value = 1.0
	transition_curvature_spin.step = 0.05
	transition_curvature_spin.editable = false
	transition_curvature_spin.value_changed.connect(_on_transition_curvature_changed)
	curvature_row.add_child(transition_curvature_spin)
	var density_row := HBoxContainer.new()
	inspector.add_child(density_row)
	var density_label := Label.new()
	density_label.text = "精度 / LOD"
	density_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	density_row.add_child(density_label)
	transition_density_option = OptionButton.new()
	for text in ["25%", "50%", "100%", "200%"]:
		transition_density_option.add_item(text)
	transition_density_option.disabled = true
	transition_density_option.item_selected.connect(_on_transition_density_selected)
	density_row.add_child(transition_density_option)
	transition_lod_option = OptionButton.new()
	for text in ["LOD 0", "LOD 1", "LOD 2"]:
		transition_lod_option.add_item(text)
	transition_lod_option.disabled = true
	transition_lod_option.item_selected.connect(_on_transition_lod_selected)
	density_row.add_child(transition_lod_option)
	_add_hint(inspector, "外圈贴合主体，内圈接入窗根。\n厚度默认按主体曲率自适应。")
	_add_heading(inspector, "共享材质 · 框架")
	frame_slot_panel = _create_slot_panel(inspector, _on_frame_texture_changed)
	_add_heading(inspector, "共享材质 · 玻璃")
	glass_slot_panel = _create_slot_panel(inspector, _on_glass_texture_changed)
	_add_hint(inspector, "空槽使用默认外观。修改 Profile 会作用于所有引用该材质的组件。")
	_add_hint(inspector, "拖动已放置组件时仍保持吸附。\n橙色球：上下拖动调整法线倾角。\n绿色方块：左右拖动等比缩放。\n0° 表示完全遵循主体表面法线。")
	_add_heading(inspector, "融合方式")
	_add_hint(inspector, "主体与组件采用封闭实体 CSG。\n先执行全部开洞差集，再执行窗框\n与玻璃并集。组件消失时移除开洞，\n主体墙面会真实恢复。")
	deferred_fusion_toggle = CheckButton.new()
	deferred_fusion_toggle.text = "后合并编辑（轻量预览）"
	deferred_fusion_toggle.toggled.connect(_on_deferred_fusion_toggled)
	inspector.add_child(deferred_fusion_toggle)
	merge_selected_button = Button.new()
	merge_selected_button.text = "合并选中组件"
	merge_selected_button.disabled = true
	merge_selected_button.pressed.connect(_merge_selected)
	inspector.add_child(merge_selected_button)
	merge_all_button = Button.new()
	merge_all_button.text = "全部合并"
	merge_all_button.disabled = true
	merge_all_button.pressed.connect(_merge_all)
	inspector.add_child(merge_all_button)
	wireframe_button = Button.new()
	wireframe_button.text = "水密线框：关 (G)"
	wireframe_button.toggle_mode = true
	wireframe_button.focus_mode = Control.FOCUS_NONE
	wireframe_button.toggled.connect(_toggle_wireframe)
	inspector.add_child(wireframe_button)
	_add_hint(inspector, "线框模式显示实际三角网格，\n用于检查开洞与融合边界。")
	_add_heading(inspector, "快捷键")
	_add_hint(inspector, "Delete  删除选中组件\nEsc  取消拖放 / 选择\nF  重置视角\nG  切换水密线框")

func _create_slot_panel(parent: VBoxContainer, callback: Callable) -> PCGTextureSlotPanel:
	var panel := PCGTextureSlotPanel.new()
	panel.visible = false
	panel.texture_changed.connect(callback)
	panel.load_failed.connect(func(message: String): status_label.text = message)
	parent.add_child(panel)
	return panel

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
			selected.flush_transition_csg()
			status_label.text = "组件变换已更新。"
			get_viewport().set_input_as_handled()
		return
	if dragging_component:
		if event is InputEventMouseMotion and selected != null:
			_drag_selected(event.position)
			get_viewport().set_input_as_handled()
		elif event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT and not event.pressed:
			dragging_component = false
			selected.flush_transition_csg()
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
		status_label.text = "将组件预览拖到平面墙或半球圆柱主体上"

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
		handle_start_scale = selected.current_scale
		selected.set_transition_deferred(true)
		dragging_component = false
		status_label.text = "拖动角度手柄：上下调整法线倾角" if handle == "angle" else "拖动缩放手柄：左右调整整体尺寸"
		return
	var component := _pick_component(screen_position)
	_select_component(component)
	if component != null:
		component.set_transition_deferred(true)
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
		selected.neighborhood_scale = 1.0
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
	var scales := OverlapSolver.solve(components, dragged, selected)
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
		transition_toggle.disabled = true
		transition_thickness_spin.editable = false
		transition_curvature_spin.editable = false
		transition_density_option.disabled = true
		transition_lod_option.disabled = true
		merge_selected_button.disabled = true
		frame_slot_panel.visible = false
		glass_slot_panel.visible = false
		return
	selected_name_label.text = "%s · %s" % [selected.definition.display_name, selected.wall.display_name]
	selected_scale_label.text = "当前尺寸：%d%%" % roundi(selected.current_scale * 100.0)
	selected_threshold_label.text = "资产消失阈值：%d%%" % roundi(selected.definition.min_scale * 100.0)
	selected_anchor_label.text = "表面锚点：%.2f, %.2f m" % [selected.anchor.x, selected.anchor.y]
	selected_state_label.text = "状态：%s · 始终吸附" % ("已融合" if selected.active else "已消失 / 主体恢复")
	selected_state_label.add_theme_color_override("font_color", Color("83e0b5") if selected.active else Color("ff9d79"))
	attachment_angle_spin.editable = true
	attachment_angle_spin.set_value_no_signal(selected.attachment_angle_degrees)
	transition_toggle.disabled = false
	transition_toggle.set_pressed_no_signal(selected.transition_enabled)
	transition_thickness_spin.editable = selected.transition_enabled
	transition_thickness_spin.set_value_no_signal(selected.effective_transition_thickness())
	transition_curvature_spin.editable = selected.transition_enabled
	transition_curvature_spin.set_value_no_signal(selected.transition_curvature)
	transition_density_option.disabled = not selected.transition_enabled
	transition_density_option.select([0.25, 0.5, 1.0, 2.0].find(selected.transition_density))
	transition_lod_option.disabled = not selected.transition_enabled
	transition_lod_option.select(selected.transition_lod)
	merge_selected_button.disabled = not selected.wall.preview_mode
	frame_slot_panel.visible = true
	glass_slot_panel.visible = true
	frame_slot_panel.set_profile(selected.definition.frame_profile)
	glass_slot_panel.set_profile(selected.definition.glass_profile)

func _on_frame_texture_changed(_slot: StringName, _texture: Texture2D) -> void:
	_refresh_selected_materials()

func _on_glass_texture_changed(_slot: StringName, _texture: Texture2D) -> void:
	_refresh_selected_materials()

func _refresh_selected_materials() -> void:
	if selected == null:
		return
	var definition := selected.definition
	if definition.frame_profile != null:
		MaterialLibrary.profile_shader(definition.frame_material_id, preload("res://shaders/architectural_pbr.gdshader"), definition.frame_profile, {}, {}, &"preserve", definition.texture_world_size)
	if definition.glass_profile != null:
		MaterialLibrary.profile_shader(definition.glass_material_id, preload("res://shaders/architectural_pbr.gdshader"), definition.glass_profile, {}, {}, &"preserve", definition.texture_world_size)
	status_label.text = "共享材质已更新；现有组件和后续生成都会使用该 Profile。"

func _on_attachment_angle_changed(value: float) -> void:
	if selected == null:
		return
	selected.attachment_angle_degrees = value
	selected.update_transform()
	status_label.text = "法线倾角已设为 %.0f°；0° 表示完全遵循主体表面法线。" % value

func _on_transition_toggled(value: bool) -> void:
	if selected == null:
		return
	selected.set_transition_enabled(value)
	_update_inspector()
	status_label.text = "主体包裹过渡已%s。" % ("开启" if value else "关闭")

func _on_transition_thickness_changed(value: float) -> void:
	if selected == null:
		return
	selected.transition_thickness = value
	selected.update_transform()
	status_label.text = "过渡厚度已设为 %.2f m。" % value

func _on_transition_curvature_changed(value: float) -> void:
	if selected == null:
		return
	selected.transition_curvature = value
	selected.update_transform()
	status_label.text = "过渡弧度已更新。"

func _on_transition_density_selected(index: int) -> void:
	if selected == null:
		return
	selected.transition_density = [0.25, 0.5, 1.0, 2.0][index]
	selected.update_transform()
	status_label.text = "过渡精度已更新。"

func _on_transition_lod_selected(index: int) -> void:
	if selected == null:
		return
	selected.transition_lod = index
	selected.update_transform()
	status_label.text = "过渡 LOD 已切换为 LOD %d。" % index

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

func _on_deferred_fusion_toggled(value: bool) -> void:
	for host in hosts:
		host.set_preview_mode(value)
	merge_all_button.disabled = not value
	merge_selected_button.disabled = not value or selected == null
	status_label.text = "后合并编辑已开启；只更新轻量预览。" if value else "已完成全部融合。"

func _merge_selected() -> void:
	if selected == null:
		return
	selected.wall.merge_component(selected)
	selected.set_direct_preview(false)
	status_label.text = "已合并选中组件；其他组件继续保持轻量预览。"

func _merge_all() -> void:
	for host in hosts:
		host.set_preview_mode(false)
	for component in components:
		component.set_direct_preview(false)
		component.flush_transition_csg()
	merge_all_button.disabled = true
	merge_selected_button.disabled = true
	deferred_fusion_toggle.set_pressed_no_signal(false)
	status_label.text = "全部主体与组件已完成水密融合。"

func _toggle_wireframe(enabled: bool) -> void:
	for host in hosts:
		host.set_wireframe(enabled)
	for component in components:
		component.set_transition_wireframe(enabled)
		component.set_direct_wireframe(enabled)
	wireframe_button.text = "水密线框：%s (G)" % ("开" if enabled else "关")
	status_label.text = "已切换为最终融合网格线框；再次按 G 恢复实体显示。" if enabled else "已恢复实体材质显示。"

func _screen_for_anchor(anchor: Vector2) -> Vector2:
	return camera.unproject_position(wall.surface_transform(anchor).origin)

func _run_visual_check() -> void:
	await get_tree().physics_frame
	var component := _place_component(&"arch_window", Vector2(0.0, 0.4), wall)
	component.transition_thickness = 0.35
	component.transition_curvature = 0.65
	component.update_transform()
	await get_tree().process_frame
	await get_tree().process_frame
	_select_component(component)
	camera_target = wall.global_position + Vector3(0.0, 0.45, 0.0)
	camera_yaw = 0.75
	camera_pitch = 0.18
	camera_distance = 6.5
	_update_camera()
	status_label.text = "拱形窗验收：下部 2/3 矩形，上部 1/3 椭圆弧；按 G 检查过渡。"
	await get_tree().create_timer(2.0).timeout
	print("PCG_VISUAL_FPS ", Engine.get_frames_per_second())
	component.set_transition_deferred(true)
	for i in 20:
		component.anchor.x = sin(float(i) * 0.2) * 0.2
		component.update_transform()
		await get_tree().process_frame
	print("PCG_DRAG_FPS ", Engine.get_frames_per_second())
	component.flush_transition_csg()

func _run_smoke_test() -> void:
	var runner := SmokeTestRunner.new()
	runner.main = self
	await runner.run()
