extends Node3D

const PipeBuilder = preload("res://scripts/pipe_mesh_builder.gd")
const SurfaceSolver = preload("res://scripts/surface_path_solver.gd")

var camera: Camera3D
var pipe_root: Node3D
var preview_root: Node3D
var main_box: StaticBody3D
var pipe_material: ShaderMaterial
var connector_material: StandardMaterial3D
var line_material: StandardMaterial3D
var marker_material: StandardMaterial3D
var selected_marker_material: StandardMaterial3D
var axis_material: StandardMaterial3D

var control_points: Array[Vector3] = []
var control_normals: Array[Vector3] = []
var control_hard_corners: Array[bool] = []
var control_angles: Array[float] = []
var control_corner_segments: Array[int] = []
var control_wall_offsets: Array[float] = []
var control_colliders: Array = []
var path_points: Array[Vector3] = []
var path_normals: Array[Vector3] = []
var path_wall_offsets: Array[float] = []
var path_collider: CollisionObject3D
var paint_points: Array[Vector3] = []
var paint_normals: Array[Vector3] = []
var paint_hard_corners: Array[bool] = []
var paint_crease_count: int = 0
var paint_collider: CollisionObject3D
var pending_start: Dictionary = {}
var painting: bool = false
var orbiting: bool = false
var dragging_control: bool = false
var dragging_wall_offset: bool = false
var wall_offset_drag_y: float = 0.0
var wall_offset_drag_value: float = 0.0
var selected_control: int = -1
var appended_control_on_click: bool = false
var mode: String = "endpoints"
var history: Array = []
var current_pipe_id: int = 1
var completed_pipe_count: int = 0
var pipe_finalized: bool = false
var generated_length: float = 0.0
var generated_vertex_count: int = 0

var segments: Array = [{"end": 1.0, "diameter": 0.34}]
var radial_segments: int = 24
var texture_world_size: float = 0.65
var clearance: float = 0.035
var default_corner_segments: int = 8

var camera_target := Vector3(0.0, 1.5, 0.0)
var camera_yaw: float = 0.66
var camera_pitch: float = 0.43
var camera_distance: float = 12.5

var status_label: Label
var stats_label: Label
var segments_box: VBoxContainer
var endpoints_button: Button
var paint_button: Button
var edit_button: Button
var selected_control_label: Label
var corner_mode_option: OptionButton
var angle_spin: SpinBox
var corner_segments_spin: SpinBox
var wall_offset_spin: SpinBox
var apply_angle_button: Button
var right_angle_button: Button

func _ready() -> void:
	_build_environment()
	_build_surfaces()
	_build_camera()
	_build_materials()
	pipe_root = Node3D.new()
	pipe_root.name = "Pipe_001"
	add_child(pipe_root)
	preview_root = Node3D.new()
	preview_root.name = "PathPreview"
	add_child(preview_root)
	_build_ui()
	_update_camera()
	_create_demo_pipe()
	_set_mode("edit")

func _build_environment() -> void:
	var world_environment := WorldEnvironment.new()
	var environment := Environment.new()
	environment.background_mode = Environment.BG_COLOR
	environment.background_color = Color("17232c")
	environment.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	environment.ambient_light_color = Color("b8cfdb")
	environment.ambient_light_energy = 0.65
	environment.tonemap_mode = Environment.TONE_MAPPER_FILMIC
	world_environment.environment = environment
	add_child(world_environment)
	var sun := DirectionalLight3D.new()
	sun.rotation_degrees = Vector3(-52.0, -32.0, 0.0)
	sun.light_color = Color("ffe4bd")
	sun.light_energy = 1.35
	sun.shadow_enabled = true
	add_child(sun)
	var fill := DirectionalLight3D.new()
	fill.rotation_degrees = Vector3(-25.0, 145.0, 0.0)
	fill.light_color = Color("7fb9e8")
	fill.light_energy = 0.45
	add_child(fill)

func _surface_material(color: Color, roughness: float = 0.82) -> StandardMaterial3D:
	var material := StandardMaterial3D.new()
	material.albedo_color = color
	material.roughness = roughness
	return material

func _build_surfaces() -> void:
	_create_box("Ground", Vector3(14.0, 0.35, 11.0), Vector3(0.0, -0.2, 0.0), Color("35434b"))
	main_box = _create_box("MainBlock", Vector3(4.0, 4.0, 2.4), Vector3(0.0, 2.0, 0.0), Color("8c7965"))
	_create_box("SideBlock", Vector3(2.1, 2.5, 3.2), Vector3(-3.6, 1.25, 0.3), Color("526d73"))
	_create_cylinder("RoundTower", 1.45, 3.4, Vector3(3.65, 1.7, 0.0), Color("6d7488"))
	_create_box("LowStep", Vector3(2.4, 0.75, 2.0), Vector3(1.0, 0.375, 3.25), Color("756b62"))

func _create_box(label: String, size: Vector3, position: Vector3, color: Color) -> StaticBody3D:
	var body := StaticBody3D.new()
	body.name = label
	body.position = position
	add_child(body)
	var mesh_instance := MeshInstance3D.new()
	var mesh := BoxMesh.new()
	mesh.size = size
	mesh_instance.mesh = mesh
	mesh_instance.material_override = _surface_material(color)
	body.add_child(mesh_instance)
	var collision := CollisionShape3D.new()
	var shape := BoxShape3D.new()
	shape.size = size
	collision.shape = shape
	body.add_child(collision)
	return body

func _create_cylinder(label: String, radius: float, height: float, position: Vector3, color: Color) -> StaticBody3D:
	var body := StaticBody3D.new()
	body.name = label
	body.position = position
	add_child(body)
	var mesh_instance := MeshInstance3D.new()
	var mesh := CylinderMesh.new()
	mesh.top_radius = radius
	mesh.bottom_radius = radius
	mesh.height = height
	mesh.radial_segments = 48
	mesh.rings = 1
	mesh_instance.mesh = mesh
	mesh_instance.material_override = _surface_material(color)
	body.add_child(mesh_instance)
	var collision := CollisionShape3D.new()
	var shape := CylinderShape3D.new()
	shape.radius = radius
	shape.height = height
	collision.shape = shape
	body.add_child(collision)
	return body

func _build_camera() -> void:
	camera = Camera3D.new()
	camera.name = "OrbitCamera"
	camera.fov = 48.0
	camera.near = 0.05
	camera.far = 150.0
	camera.current = true
	add_child(camera)

func _build_materials() -> void:
	pipe_material = ShaderMaterial.new()
	pipe_material.shader = preload("res://shaders/pipe_grid.gdshader")
	connector_material = _surface_material(Color("d29b45"), 0.3)
	connector_material.metallic = 0.72
	line_material = _surface_material(Color("ffe66d"))
	line_material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	line_material.no_depth_test = true
	marker_material = _surface_material(Color("72f1b8"))
	marker_material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	marker_material.no_depth_test = true
	selected_marker_material = _surface_material(Color("ff8a5b"))
	selected_marker_material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	selected_marker_material.no_depth_test = true
	axis_material = _surface_material(Color("55a8ff"))
	axis_material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	axis_material.no_depth_test = true

func _build_ui() -> void:
	var canvas := CanvasLayer.new()
	add_child(canvas)
	var title_panel := PanelContainer.new()
	title_panel.set_anchors_preset(Control.PRESET_TOP_LEFT)
	title_panel.offset_left = 18.0
	title_panel.offset_top = 18.0
	title_panel.offset_right = 610.0
	title_panel.offset_bottom = 112.0
	canvas.add_child(title_panel)
	var title_box := VBoxContainer.new()
	title_panel.add_child(title_box)
	var title := Label.new()
	title.text = "PipeWeaver · 管道 PCG"
	title.add_theme_font_size_override("font_size", 23)
	title_box.add_child(title)
	status_label = Label.new()
	status_label.text = "正在准备示例…"
	status_label.add_theme_color_override("font_color", Color("b9d8e8"))
	title_box.add_child(status_label)
	stats_label = Label.new()
	stats_label.text = "左键编辑路径，右键拖动环绕，滚轮缩放"
	stats_label.add_theme_color_override("font_color", Color("8fa6b2"))
	title_box.add_child(stats_label)

	var panel := PanelContainer.new()
	panel.set_anchors_preset(Control.PRESET_RIGHT_WIDE)
	panel.offset_left = -360.0
	panel.offset_right = -18.0
	panel.offset_top = 18.0
	panel.offset_bottom = -18.0
	panel.add_theme_font_size_override("font_size", 15)
	canvas.add_child(panel)
	var panel_margin := MarginContainer.new()
	panel_margin.add_theme_constant_override("margin_left", 10)
	panel_margin.add_theme_constant_override("margin_right", 10)
	panel.add_child(panel_margin)
	var scroll := ScrollContainer.new()
	panel_margin.add_child(scroll)
	var box := VBoxContainer.new()
	box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	box.add_theme_constant_override("separation", 9)
	scroll.add_child(box)
	_add_heading(box, "路径输入")
	var mode_row := HBoxContainer.new()
	box.add_child(mode_row)
	endpoints_button = Button.new()
	endpoints_button.text = "起止点"
	endpoints_button.toggle_mode = true
	endpoints_button.button_pressed = true
	endpoints_button.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	endpoints_button.pressed.connect(_set_mode.bind("endpoints"))
	mode_row.add_child(endpoints_button)
	paint_button = Button.new()
	paint_button.text = "Paint"
	paint_button.toggle_mode = true
	paint_button.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	paint_button.pressed.connect(_set_mode.bind("paint"))
	mode_row.add_child(paint_button)
	edit_button = Button.new()
	edit_button.text = "路径编辑"
	edit_button.toggle_mode = true
	edit_button.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	edit_button.pressed.connect(_set_mode.bind("edit"))
	mode_row.add_child(edit_button)
	_add_hint(box, "起止点：可跨两个主体，自动选择最短贴合路径\nPaint：点击现有管道插入点；空白拖动绘制\n蓝色 Z 轴：单独调整该节点离墙距离")
	_add_heading(box, "当前管道")
	var pipe_lifecycle_row := HBoxContainer.new()
	box.add_child(pipe_lifecycle_row)
	var finish_pipe_button := Button.new()
	finish_pipe_button.text = "完成当前管道"
	finish_pipe_button.custom_minimum_size.y = 36.0
	finish_pipe_button.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	finish_pipe_button.pressed.connect(_finish_current_pipe)
	pipe_lifecycle_row.add_child(finish_pipe_button)
	var new_pipe_button := Button.new()
	new_pipe_button.text = "新建下一根管道"
	new_pipe_button.custom_minimum_size.y = 36.0
	new_pipe_button.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	new_pipe_button.pressed.connect(_new_pipe)
	pipe_lifecycle_row.add_child(new_pipe_button)
	_add_hint(box, "完成：冻结当前管体并隐藏控制点\n新建：保留旧管道，开始编辑下一根")
	_add_heading(box, "选中控制点")
	selected_control_label = Label.new()
	selected_control_label.text = "未选择中间节点"
	box.add_child(selected_control_label)
	corner_mode_option = OptionButton.new()
	corner_mode_option.add_item("平滑弯头", 0)
	corner_mode_option.add_item("直角/硬转角", 1)
	corner_mode_option.item_selected.connect(_on_corner_mode_changed)
	box.add_child(corner_mode_option)
	angle_spin = _add_spin(box, "路径内夹角", 15.0, 180.0, 5.0, 90.0, _on_angle_changed)
	corner_segments_spin = _add_spin(box, "转角分段", 2.0, 32.0, 1.0, 8.0, _on_corner_segments_changed)
	wall_offset_spin = _add_spin(box, "节点离墙距离", 0.0, 3.0, 0.01, 0.0, _on_wall_offset_changed)
	apply_angle_button = Button.new()
	apply_angle_button.text = "应用节点转角"
	apply_angle_button.pressed.connect(_apply_selected_angle)
	box.add_child(apply_angle_button)
	right_angle_button = Button.new()
	right_angle_button.text = "设为 90°直角弯管"
	right_angle_button.pressed.connect(_set_right_angle)
	box.add_child(right_angle_button)
	_update_control_settings()
	_add_heading(box, "管道参数")
	_add_spin(box, "环向分段", 12.0, 48.0, 4.0, radial_segments, _on_radial_changed)
	_add_spin(box, "贴图世界尺寸", 0.2, 2.0, 0.05, texture_world_size, _on_texture_size_changed)
	_add_spin(box, "表面间隙", 0.0, 0.3, 0.005, clearance, _on_clearance_changed)
	_add_spin(box, "默认转角分段", 2.0, 32.0, 1.0, default_corner_segments, _on_default_segments_changed)
	_add_heading(box, "直径分段")
	_add_hint(box, "终点按路径比例划分；最后一固定为 100%")
	segments_box = VBoxContainer.new()
	segments_box.add_theme_constant_override("separation", 5)
	box.add_child(segments_box)
	_rebuild_segment_rows()
	var add_segment := Button.new()
	add_segment.text = "+ 添加变径分段"
	add_segment.pressed.connect(_add_segment)
	box.add_child(add_segment)
	_add_heading(box, "编辑")
	var edit_row := HBoxContainer.new()
	box.add_child(edit_row)
	var undo_button := Button.new()
	undo_button.text = "撤销路径"
	undo_button.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	undo_button.pressed.connect(_undo)
	edit_row.add_child(undo_button)
	var clear_button := Button.new()
	clear_button.text = "清除"
	clear_button.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	clear_button.pressed.connect(_clear_path)
	edit_row.add_child(clear_button)
	var delete_control_button := Button.new()
	delete_control_button.text = "删除选中控制点 (Delete)"
	delete_control_button.pressed.connect(_delete_selected_control)
	box.add_child(delete_control_button)
	var focus_button := Button.new()
	focus_button.text = "重置视角 (F)"
	focus_button.pressed.connect(_reset_camera)
	box.add_child(focus_button)
	_add_hint(box, "Esc 取消当前输入/选择 · Ctrl/Cmd+Z 撤销\n非编辑模式下 Delete 清除整条路径")

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
	label.add_theme_font_size_override("font_size", 14)
	label.add_theme_color_override("font_color", Color("8fa6b2"))
	parent.add_child(label)

func _add_spin(parent: VBoxContainer, text: String, minimum: float, maximum: float, step: float, value: float, callback: Callable) -> SpinBox:
	var row := HBoxContainer.new()
	parent.add_child(row)
	var label := Label.new()
	label.text = text
	label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(label)
	var spin := SpinBox.new()
	spin.min_value = minimum
	spin.max_value = maximum
	spin.step = step
	spin.value = value
	spin.custom_minimum_size.x = 105.0
	spin.value_changed.connect(callback)
	row.add_child(spin)
	return spin

func _rebuild_segment_rows() -> void:
	if segments_box == null:
		return
	for child in segments_box.get_children():
		segments_box.remove_child(child)
		child.queue_free()
	for i in segments.size():
		var row := HBoxContainer.new()
		segments_box.add_child(row)
		var label := Label.new()
		label.text = "%d" % (i + 1)
		row.add_child(label)
		var end_spin := SpinBox.new()
		end_spin.prefix = "止"
		end_spin.suffix = "%"
		end_spin.min_value = 5.0
		end_spin.max_value = 100.0
		end_spin.step = 1.0
		end_spin.value = float(segments[i]["end"]) * 100.0
		end_spin.editable = i < segments.size() - 1
		end_spin.value_changed.connect(_on_segment_end_changed.bind(i))
		end_spin.custom_minimum_size.x = 86.0
		row.add_child(end_spin)
		var diameter_spin := SpinBox.new()
		diameter_spin.prefix = "Ø"
		diameter_spin.min_value = 0.08
		diameter_spin.max_value = 1.5
		diameter_spin.step = 0.02
		diameter_spin.value = float(segments[i]["diameter"])
		diameter_spin.value_changed.connect(_on_segment_diameter_changed.bind(i))
		diameter_spin.custom_minimum_size.x = 94.0
		row.add_child(diameter_spin)
		var remove := Button.new()
		remove.text = "×"
		remove.disabled = segments.size() == 1
		remove.pressed.connect(_remove_segment.bind(i))
		row.add_child(remove)

func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventMouseButton:
		if event.button_index == MOUSE_BUTTON_RIGHT:
			orbiting = event.pressed
			get_viewport().set_input_as_handled()
		elif event.button_index == MOUSE_BUTTON_WHEEL_UP and event.pressed:
			camera_distance = maxf(3.0, camera_distance * 0.9)
			_update_camera()
		elif event.button_index == MOUSE_BUTTON_WHEEL_DOWN and event.pressed:
			camera_distance = minf(35.0, camera_distance * 1.1)
			_update_camera()
		elif event.button_index == MOUSE_BUTTON_LEFT:
			if mode == "paint":
				if event.pressed:
					_begin_paint(event.position)
				elif painting:
					_finish_paint()
			elif mode == "edit":
				if event.pressed:
					_edit_button_down(event.position, event.shift_pressed or event.double_click)
				elif dragging_wall_offset:
					dragging_wall_offset = false
					status_label.text = "控制点 %d 离墙距离 %.2f m · 全局间隙 %.3f m" % [selected_control + 1, control_wall_offsets[selected_control], clearance]
				elif dragging_control:
					_edit_button_up()
			elif event.pressed:
				_endpoint_click(event.position)
	elif event is InputEventMouseMotion:
		if orbiting:
			camera_yaw -= event.relative.x * 0.006
			camera_pitch = clampf(camera_pitch + event.relative.y * 0.005, -0.15, 1.35)
			_update_camera()
		elif dragging_wall_offset:
			_drag_wall_offset(event.position.y)
		elif dragging_control:
			_drag_selected_control(event.position)
		elif painting:
			_append_paint_point(event.position)
	elif event is InputEventKey and event.pressed and not event.echo:
		if event.keycode == KEY_F:
			_reset_camera()
		elif event.keycode == KEY_ESCAPE:
			_cancel_input()
		elif event.keycode == KEY_DELETE:
			if mode == "edit" and selected_control >= 0:
				_delete_selected_control()
			else:
				_clear_path()
		elif event.keycode == KEY_Z and (event.ctrl_pressed or event.meta_pressed):
			_undo()

func _update_camera() -> void:
	if camera == null:
		return
	var offset := Vector3(cos(camera_pitch) * sin(camera_yaw), sin(camera_pitch), cos(camera_pitch) * cos(camera_yaw)) * camera_distance
	camera.position = camera_target + offset
	camera.look_at(camera_target, Vector3.UP)

func _reset_camera() -> void:
	camera_target = Vector3(0.0, 1.5, 0.0)
	camera_yaw = 0.66
	camera_pitch = 0.43
	camera_distance = 12.5
	_update_camera()

func _pick(screen_position: Vector2) -> Dictionary:
	var origin: Vector3 = camera.project_ray_origin(screen_position)
	var direction: Vector3 = camera.project_ray_normal(screen_position)
	var query := PhysicsRayQueryParameters3D.create(origin, origin + direction * 100.0)
	var hit: Dictionary = get_world_3d().direct_space_state.intersect_ray(query)
	if not hit.is_empty() and hit["normal"].dot(direction) > 0.0:
		hit["normal"] = -hit["normal"]
	return hit

func _set_mode(new_mode: String) -> void:
	if pipe_finalized and new_mode == "edit":
		mode = "finished"
		endpoints_button.button_pressed = false
		paint_button.button_pressed = false
		edit_button.button_pressed = false
		_cancel_input()
		_clear_children(preview_root)
		status_label.text = "当前管道已完成并冻结；请点击“新建管道”继续。"
		return
	mode = new_mode
	endpoints_button.button_pressed = mode == "endpoints"
	paint_button.button_pressed = mode == "paint"
	edit_button.button_pressed = mode == "edit"
	_cancel_input()
	if mode == "endpoints":
		status_label.text = "点击立体表面设置起点。"
	elif mode == "paint":
		status_label.text = "点击现有管道插入控制点；在空白表面拖动绘制新路径。"
	elif control_points.size() >= 2:
		status_label.text = "拖动控制点；空白处追加，Shift/双击插入中间点。"
	else:
		status_label.text = "请先用起止点或 Paint 创建一条路径。"

func _finish_current_pipe() -> void:
	if pipe_finalized:
		status_label.text = "当前管道已经完成；可点击“新建管道”。"
		return
	if control_points.size() < 2:
		status_label.text = "当前没有可完成的管道。"
		return
	_cancel_input()
	pipe_finalized = true
	mode = "finished"
	history.clear()
	completed_pipe_count += 1
	endpoints_button.button_pressed = false
	paint_button.button_pressed = false
	edit_button.button_pressed = false
	_clear_children(preview_root)
	status_label.text = "%s 已完成并停止编辑；新建管道不会覆盖它。" % pipe_root.name
	stats_label.text = "已完成 %d 根管道 · 当前管体已冻结" % completed_pipe_count
	print("PIPE_FINALIZED ", pipe_root.name, " children=", pipe_root.get_child_count())

func _new_pipe(new_mode: String = "endpoints") -> void:
	if not pipe_finalized and control_points.size() >= 2:
		_finish_current_pipe()
	current_pipe_id += 1
	pipe_root = Node3D.new()
	pipe_root.name = "Pipe_%03d" % current_pipe_id
	add_child(pipe_root)
	control_points.clear()
	control_normals.clear()
	control_hard_corners.clear()
	control_angles.clear()
	control_corner_segments.clear()
	control_wall_offsets.clear()
	control_colliders.clear()
	path_points.clear()
	path_normals.clear()
	path_wall_offsets.clear()
	path_collider = null
	paint_points.clear()
	paint_normals.clear()
	paint_hard_corners.clear()
	paint_crease_count = 0
	pending_start.clear()
	selected_control = -1
	history.clear()
	pipe_finalized = false
	_clear_children(preview_root)
	_set_mode(new_mode)
	stats_label.text = "已完成 %d 根 · 正在编辑 %s" % [completed_pipe_count, pipe_root.name]
	print("PIPE_STARTED ", pipe_root.name)

func _endpoint_click(screen_position: Vector2) -> void:
	if pipe_finalized:
		_new_pipe("endpoints")
	var hit: Dictionary = _pick(screen_position)
	if hit.is_empty():
		status_label.text = "没有命中可绘制表面，请点击实体。"
		return
	if pending_start.is_empty():
		pending_start = hit
		status_label.text = "起点已设置；可在另一主体选择终点，自动计算最短贴合路径。"
		_update_preview([], [])
		_add_marker(hit["position"], hit["normal"])
		return
	var solved: Dictionary = SurfaceSolver.find_path(pending_start, hit)
	if solved.has("error"):
		status_label.text = solved["error"]
		return
	_commit_path(solved["points"], solved["normals"], pending_start["collider"], "起止点管道已生成", solved.get("hard_corners", []), solved.get("colliders", []))

func _begin_paint(screen_position: Vector2) -> void:
	if pipe_finalized:
		_new_pipe("paint")
	var hit: Dictionary = _pick(screen_position)
	if hit.is_empty():
		status_label.text = "Paint 必须从立体表面开始。"
		return
	if _try_paint_insert(hit):
		return
	painting = true
	paint_points = [hit["position"]]
	paint_normals = [hit["normal"]]
	paint_hard_corners = [false]
	paint_crease_count = 0
	paint_collider = hit["collider"]
	_update_preview(paint_points, paint_normals)
	status_label.text = "正在 Paint… 松开左键生成管道"

func _try_paint_insert(hit: Dictionary) -> bool:
	if control_points.size() < 2 or hit["collider"] != path_collider:
		return false
	var segment_index: int = _nearest_control_segment(hit["position"])
	var distance: float = sqrt(_segment_distance_squared(hit["position"], control_points[segment_index], control_points[segment_index + 1]))
	if distance > 0.55:
		return false
	for point in control_points:
		if point.distance_to(hit["position"]) < 0.12:
			status_label.text = "这里已有控制点；可在路径编辑模式拖动它。"
			return true
	_remember_path()
	var insert_index: int = segment_index + 1
	control_points.insert(insert_index, hit["position"])
	control_normals.insert(insert_index, hit["normal"])
	control_hard_corners.insert(insert_index, false)
	control_angles.insert(insert_index, 90.0)
	control_corner_segments.insert(insert_index, default_corner_segments)
	control_wall_offsets.insert(insert_index, 0.0)
	control_colliders.insert(insert_index, path_collider)
	selected_control = insert_index
	_rebuild_from_controls()
	status_label.text = "已通过 Paint 在管道上插入控制点 %d；可继续点击路径添加。" % (insert_index + 1)
	return true

func _append_paint_point(screen_position: Vector2) -> void:
	var hit: Dictionary = _pick(screen_position)
	if hit.is_empty() or hit["collider"] != paint_collider:
		return
	if paint_points[-1].distance_to(hit["position"]) < 0.16:
		return
	var normal_dot: float = paint_normals[-1].dot(hit["normal"])
	if normal_dot < -0.25:
		return
	if normal_dot < 0.7071:
		var crease: Dictionary = _surface_crease(paint_points[-1], paint_normals[-1], hit["position"], hit["normal"])
		if not crease.is_empty():
			paint_points.append(crease["position"])
			paint_normals.append(crease["normal"])
			paint_hard_corners.append(true)
			paint_crease_count += 1
	paint_points.append(hit["position"])
	paint_normals.append(hit["normal"])
	paint_hard_corners.append(false)
	_update_preview(paint_points, paint_normals)

func _surface_crease(first_point: Vector3, first_normal: Vector3, second_point: Vector3, second_normal: Vector3) -> Dictionary:
	var n1: Vector3 = first_normal.normalized()
	var n2: Vector3 = second_normal.normalized()
	var direction: Vector3 = n1.cross(n2)
	if direction.length_squared() < 0.001:
		return {}
	direction = direction.normalized()
	var d1: float = n1.dot(first_point)
	var d2: float = n2.dot(second_point)
	var line_point: Vector3 = (n2.cross(direction) * d1 + direction.cross(n1) * d2) / direction.length_squared()
	var midpoint: Vector3 = (first_point + second_point) * 0.5
	var edge_point: Vector3 = line_point + direction * (midpoint - line_point).dot(direction)
	if edge_point.distance_to(first_point) < 0.04 or edge_point.distance_to(second_point) < 0.04:
		return {}
	var average_normal: Vector3 = (n1 + n2).normalized()
	var projected: Dictionary = SurfaceSolver.project(edge_point, average_normal, paint_collider, get_world_3d().direct_space_state)
	if projected.is_empty():
		projected = SurfaceSolver.project(edge_point, n1, paint_collider, get_world_3d().direct_space_state)
	if projected.is_empty():
		projected = SurfaceSolver.project(edge_point, n2, paint_collider, get_world_3d().direct_space_state)
	return {"position": edge_point if projected.is_empty() else projected["position"], "normal": average_normal}

func _finish_paint() -> void:
	painting = false
	if paint_points.size() < 2:
		status_label.text = "Paint 路径太短，请按住左键拖出一段距离。"
		_update_preview(path_points, path_normals)
		return
	_commit_path(paint_points, paint_normals, paint_collider, "Paint 管道已生成", paint_hard_corners)
	if paint_crease_count > 0:
		status_label.text = "Paint 管道已生成 · %d 个控制点 · %d 处自适应转角" % [control_points.size(), paint_crease_count]

func _commit_path(points: Array, normals: Array, collider: CollisionObject3D, message: String, automatic_hard_corners: Array = [], point_colliders: Array = []) -> void:
	_remember_path()
	control_points.assign(points)
	control_normals.assign(normals)
	control_hard_corners.clear()
	control_angles.clear()
	control_corner_segments.clear()
	control_wall_offsets.clear()
	control_colliders.clear()
	control_colliders.clear()
	for i in control_points.size():
		control_hard_corners.append(automatic_hard_corners.size() == control_points.size() and automatic_hard_corners[i])
		control_angles.append(90.0)
		control_corner_segments.append(default_corner_segments)
		control_wall_offsets.append(0.0)
		control_colliders.append(point_colliders[i] if point_colliders.size() == control_points.size() else collider)
	path_collider = collider
	selected_control = -1
	pending_start.clear()
	_rebuild_from_controls()
	if not status_label.text.contains("失败"):
		status_label.text = "%s · %d 个控制点" % [message, control_points.size()]

func _rebuild_from_controls() -> void:
	if pipe_finalized:
		return
	if control_points.size() < 2 or path_collider == null:
		path_points.clear()
		path_normals.clear()
		path_wall_offsets.clear()
		_clear_children(pipe_root)
		_update_preview([], [])
		_update_control_settings()
		return
	var smoothed: Dictionary = SurfaceSolver.smooth_and_project(control_points, control_normals, path_collider, 0, get_world_3d().direct_space_state, control_hard_corners, control_corner_segments, control_wall_offsets, control_colliders)
	path_points.assign(smoothed["points"])
	path_normals.assign(smoothed["normals"])
	path_wall_offsets.assign(smoothed["wall_offsets"])
	_generate_pipe()
	_add_hard_corner_connectors()
	stats_label.text = "长度 %.2f m · %d 顶点 · %d 个接头" % [generated_length, generated_vertex_count, pipe_root.get_child_count() - 1]
	_update_preview(path_points, path_normals)
	_update_control_settings()

func _update_control_settings() -> void:
	if angle_spin == null:
		return
	var valid: bool = selected_control > 0 and selected_control < control_points.size() - 1 and control_hard_corners.size() == control_points.size()
	var has_selection: bool = selected_control >= 0 and selected_control < control_wall_offsets.size()
	selected_control_label.text = "控制点 %d · 中间节点" % (selected_control + 1) if valid else ("控制点 %d · 端点" % (selected_control + 1) if has_selection else "请选择一个中间节点")
	corner_mode_option.disabled = not valid
	angle_spin.editable = valid
	corner_segments_spin.editable = valid and not control_hard_corners[selected_control]
	wall_offset_spin.editable = has_selection
	apply_angle_button.disabled = not valid
	right_angle_button.disabled = not valid
	if valid:
		corner_mode_option.select(1 if control_hard_corners[selected_control] else 0)
		angle_spin.set_value_no_signal(control_angles[selected_control])
		corner_segments_spin.set_value_no_signal(control_corner_segments[selected_control])
	if has_selection:
		wall_offset_spin.set_value_no_signal(control_wall_offsets[selected_control])

func _on_corner_mode_changed(index: int) -> void:
	if selected_control <= 0 or selected_control >= control_points.size() - 1:
		return
	_remember_path()
	control_hard_corners[selected_control] = index == 1
	_rebuild_from_controls()
	status_label.text = "控制点 %d 已切换为%s。" % [selected_control + 1, "硬转角" if index == 1 else "平滑弯头"]

func _on_angle_changed(value: float) -> void:
	if selected_control > 0 and selected_control < control_angles.size() - 1:
		control_angles[selected_control] = value

func _on_corner_segments_changed(value: float) -> void:
	if selected_control <= 0 or selected_control >= control_corner_segments.size() - 1:
		return
	_remember_path()
	control_corner_segments[selected_control] = int(value)
	_rebuild_from_controls()
	status_label.text = "控制点 %d 的圆角已设为 %d 段。" % [selected_control + 1, int(value)]

func _on_default_segments_changed(value: float) -> void:
	default_corner_segments = int(value)
	status_label.text = "后续新控制点将默认使用 %d 段圆角。" % default_corner_segments

func _on_wall_offset_changed(value: float) -> void:
	if selected_control < 0 or selected_control >= control_wall_offsets.size():
		return
	_remember_path()
	control_wall_offsets[selected_control] = value
	_rebuild_from_controls()
	status_label.text = "控制点 %d 的独立离墙距离为 %.2f m；全局表面间隙仍叠加生效。" % [selected_control + 1, value]

func _set_right_angle() -> void:
	if selected_control <= 0 or selected_control >= control_points.size() - 1:
		return
	control_hard_corners[selected_control] = true
	angle_spin.value = 90.0
	control_angles[selected_control] = 90.0
	_apply_selected_angle()

func _apply_selected_angle() -> void:
	if selected_control <= 0 or selected_control >= control_points.size() - 1:
		return
	var incoming: Vector3 = control_points[selected_control] - control_points[selected_control - 1]
	var outgoing: Vector3 = control_points[selected_control + 1] - control_points[selected_control]
	if incoming.length_squared() < 0.0001 or outgoing.length_squared() < 0.0001:
		status_label.text = "相邻控制点距离太短，无法计算转角。"
		return
	_remember_path()
	incoming = incoming.normalized()
	var axis: Vector3 = control_normals[selected_control].normalized()
	var turn_sign: float = signf(axis.dot(incoming.cross(outgoing.normalized())))
	if is_zero_approx(turn_sign):
		turn_sign = 1.0
	var deflection: float = deg_to_rad(180.0 - control_angles[selected_control])
	var direction: Vector3 = incoming.rotated(axis, turn_sign * deflection).normalized()
	var candidate: Vector3 = control_points[selected_control] + direction * outgoing.length()
	var next_surface: CollisionObject3D = control_colliders[selected_control + 1]
	var current_surface: CollisionObject3D = control_colliders[selected_control]
	var projected: Dictionary = SurfaceSolver.project(candidate, control_normals[selected_control + 1], next_surface, get_world_3d().direct_space_state)
	if projected.is_empty():
		projected = SurfaceSolver.project(candidate, control_normals[selected_control], current_surface, get_world_3d().direct_space_state)
	if projected.is_empty():
		status_label.text = "目标角度会离开当前表面，未应用。"
		return
	control_points[selected_control + 1] = projected["position"]
	control_normals[selected_control + 1] = projected["normal"]
	_rebuild_from_controls()
	status_label.text = "控制点 %d 已应用 %.0f° 内夹角；曲面以投射结果为准。" % [selected_control + 1, control_angles[selected_control]]

func _add_hard_corner_connectors() -> void:
	for i in range(1, control_points.size() - 1):
		if not control_hard_corners[i]:
			continue
		var ratio: float = float(i) / float(control_points.size() - 1)
		var diameter: float = segments[-1]["diameter"]
		for segment in segments:
			if ratio <= float(segment["end"]):
				diameter = segment["diameter"]
				break
		var tangent: Vector3 = (control_points[i + 1] - control_points[i - 1]).normalized()
		_create_connector({
			"position": control_points[i] + control_normals[i] * (diameter * 0.5 + clearance + control_wall_offsets[i]),
			"tangent": tangent,
			"radius": diameter * 0.5,
			"height": maxf(diameter * 0.35, 0.08),
			"kind": "flange"
		})

func _edit_button_down(screen_position: Vector2, insert: bool) -> void:
	if pipe_finalized:
		status_label.text = "当前管道已完成；请新建管道后再编辑。"
		return
	if control_points.size() < 2:
		status_label.text = "请先用起止点或 Paint 创建一条路径。"
		return
	var axis_index: int = _wall_axis_at_screen(screen_position)
	if axis_index >= 0 and not insert:
		selected_control = axis_index
		dragging_wall_offset = true
		wall_offset_drag_y = screen_position.y
		wall_offset_drag_value = control_wall_offsets[axis_index]
		appended_control_on_click = false
		_remember_path()
		_update_preview(path_points, path_normals)
		_update_control_settings()
		status_label.text = "拖动 Z 轴调整控制点 %d 的离墙距离。" % (axis_index + 1)
		return
	if insert and appended_control_on_click:
		control_points.pop_back()
		control_normals.pop_back()
		control_hard_corners.pop_back()
		control_angles.pop_back()
		control_corner_segments.pop_back()
		control_wall_offsets.pop_back()
		control_colliders.pop_back()
		if not history.is_empty():
			history.pop_back()
		appended_control_on_click = false
		selected_control = -1
		_rebuild_from_controls()
	elif not insert:
		appended_control_on_click = false
	var control_index: int = _control_at_screen(screen_position)
	if control_index >= 0:
		selected_control = control_index
		dragging_control = true
		appended_control_on_click = false
		_remember_path()
		_update_preview(path_points, path_normals)
		_update_control_settings()
		status_label.text = "拖动控制点 %d，松开左键完成。" % (selected_control + 1)
		return
	var hit: Dictionary = _pick(screen_position)
	if hit.is_empty():
		selected_control = -1
		_update_preview(path_points, path_normals)
		_update_control_settings()
		return
	if hit["collider"] != path_collider:
		status_label.text = "新控制点必须位于原路径所属的同一表面。"
		return
	_remember_path()
	var insert_index: int = control_points.size()
	if insert:
		insert_index = _nearest_control_segment(hit["position"]) + 1
	control_points.insert(insert_index, hit["position"])
	control_normals.insert(insert_index, hit["normal"])
	control_hard_corners.insert(insert_index, false)
	control_angles.insert(insert_index, 90.0)
	control_corner_segments.insert(insert_index, default_corner_segments)
	control_wall_offsets.insert(insert_index, 0.0)
	control_colliders.insert(insert_index, path_collider)
	selected_control = insert_index
	appended_control_on_click = not insert
	_rebuild_from_controls()
	status_label.text = "已在路径中插入控制点 %d。" % (insert_index + 1) if insert else "已在末尾追加控制点 %d。" % (insert_index + 1)

func _edit_button_up() -> void:
	dragging_control = false
	status_label.text = "控制点已更新 · 共 %d 个控制点" % control_points.size()

func _drag_selected_control(screen_position: Vector2) -> void:
	if selected_control < 0 or selected_control >= control_points.size():
		return
	var hit: Dictionary = _pick(screen_position)
	if hit.is_empty() or hit["collider"] != control_colliders[selected_control]:
		return
	if control_points[selected_control].distance_squared_to(hit["position"]) < 0.000001:
		return
	control_points[selected_control] = hit["position"]
	control_normals[selected_control] = hit["normal"]
	_rebuild_from_controls()

func _wall_axis_position(index: int) -> Vector3:
	return control_points[index] + control_normals[index] * (0.55 + control_wall_offsets[index])

func _wall_axis_at_screen(screen_position: Vector2) -> int:
	var best: int = -1
	var best_distance: float = 19.0
	for i in control_points.size():
		var distance: float = camera.unproject_position(_wall_axis_position(i)).distance_to(screen_position)
		if distance < best_distance:
			best_distance = distance
			best = i
	return best

func _drag_wall_offset(screen_y: float) -> void:
	if selected_control < 0 or selected_control >= control_wall_offsets.size():
		return
	control_wall_offsets[selected_control] = clampf(wall_offset_drag_value + (wall_offset_drag_y - screen_y) * 0.01, 0.0, 3.0)
	_rebuild_from_controls()
	status_label.text = "控制点 %d 离墙距离 %.2f m · 全局间隙 %.3f m" % [selected_control + 1, control_wall_offsets[selected_control], clearance]

func _delete_selected_control() -> void:
	if selected_control < 0 or selected_control >= control_points.size():
		status_label.text = "请先在路径编辑模式选择一个控制点。"
		return
	if control_points.size() <= 2:
		status_label.text = "路径至少需要起点和终点，不能继续删除。"
		return
	_remember_path()
	var deleted: int = selected_control
	control_points.remove_at(deleted)
	control_normals.remove_at(deleted)
	control_hard_corners.remove_at(deleted)
	control_angles.remove_at(deleted)
	control_corner_segments.remove_at(deleted)
	control_wall_offsets.remove_at(deleted)
	control_colliders.remove_at(deleted)
	selected_control = -1
	_rebuild_from_controls()
	status_label.text = "已删除控制点 %d，剩余 %d 个。" % [deleted + 1, control_points.size()]

func _control_at_screen(screen_position: Vector2) -> int:
	var best: int = -1
	var best_distance: float = 22.0
	for i in control_points.size():
		var marker_position: Vector3 = control_points[i] + control_normals[i] * 0.06
		var distance: float = camera.unproject_position(marker_position).distance_to(screen_position)
		if distance < best_distance:
			best_distance = distance
			best = i
	return best

func _nearest_control_segment(point: Vector3) -> int:
	var best: int = 0
	var best_distance: float = INF
	for i in range(control_points.size() - 1):
		var distance: float = _segment_distance_squared(point, control_points[i], control_points[i + 1])
		if distance < best_distance:
			best_distance = distance
			best = i
	return best

func _segment_distance_squared(point: Vector3, a: Vector3, b: Vector3) -> float:
	var segment: Vector3 = b - a
	if segment.length_squared() < 0.000001:
		return point.distance_squared_to(a)
	var t: float = clampf((point - a).dot(segment) / segment.length_squared(), 0.0, 1.0)
	return point.distance_squared_to(a + segment * t)

func _generate_pipe() -> void:
	if pipe_finalized:
		return
	_clear_children(pipe_root)
	if path_points.size() < 2:
		stats_label.text = "左键编辑路径，右键拖动环绕，滚轮缩放"
		return
	var result: Dictionary = PipeBuilder.build(path_points, path_normals, segments, radial_segments, texture_world_size, clearance, path_wall_offsets)
	if result.has("error"):
		status_label.text = "生成失败：" + result["error"]
		return
	var pipe := MeshInstance3D.new()
	pipe.name = "ContinuousPipe"
	pipe.mesh = result["mesh"]
	pipe.material_override = pipe_material
	pipe_root.add_child(pipe)
	for connector in result["connectors"]:
		_create_connector(connector)
	generated_length = result["length"]
	generated_vertex_count = result["vertex_count"]
	stats_label.text = "长度 %.2f m · %d 顶点 · %d 个接头" % [result["length"], result["vertex_count"], result["connectors"].size()]
	print("PIPE_PCG_GENERATED length=%.3f vertices=%d connectors=%d segments=%d" % [result["length"], result["vertex_count"], result["connectors"].size(), segments.size()])

func _create_connector(data: Dictionary) -> void:
	var instance := MeshInstance3D.new()
	instance.name = "Flange" if data["kind"] == "flange" else "EndpointCoupling"
	var cylinder := CylinderMesh.new()
	cylinder.top_radius = data["radius"]
	cylinder.bottom_radius = data["radius"]
	cylinder.height = data["height"]
	cylinder.radial_segments = radial_segments
	instance.mesh = cylinder
	instance.material_override = connector_material
	instance.position = data["position"]
	instance.basis = Basis(Quaternion(Vector3.UP, data["tangent"]))
	pipe_root.add_child(instance)

func _update_preview(points: Array, normals: Array) -> void:
	_clear_children(preview_root)
	if points.size() >= 2:
		var immediate := ImmediateMesh.new()
		immediate.surface_begin(Mesh.PRIMITIVE_LINES)
		for i in range(points.size() - 1):
			immediate.surface_add_vertex(points[i] + normals[i] * 0.025)
			immediate.surface_add_vertex(points[i + 1] + normals[i + 1] * 0.025)
		immediate.surface_end()
		var lines := MeshInstance3D.new()
		lines.mesh = immediate
		lines.material_override = line_material
		preview_root.add_child(lines)
	if mode == "edit":
		var axes := ImmediateMesh.new()
		axes.surface_begin(Mesh.PRIMITIVE_LINES)
		for i in control_points.size():
			axes.surface_add_vertex(control_points[i] + control_normals[i] * 0.12)
			axes.surface_add_vertex(_wall_axis_position(i))
			_add_marker(control_points[i], control_normals[i], i == selected_control)
			_add_axis_handle(_wall_axis_position(i), i == selected_control)
		axes.surface_end()
		var axis_lines := MeshInstance3D.new()
		axis_lines.mesh = axes
		axis_lines.material_override = axis_material
		preview_root.add_child(axis_lines)
	elif not points.is_empty():
		_add_marker(points[0], normals[0])
		_add_marker(points[-1], normals[-1])

func _add_axis_handle(point: Vector3, selected: bool) -> void:
	var handle := MeshInstance3D.new()
	var sphere := SphereMesh.new()
	sphere.radius = 0.105 if selected else 0.08
	sphere.height = sphere.radius * 2.0
	sphere.radial_segments = 16
	sphere.rings = 8
	handle.mesh = sphere
	handle.material_override = axis_material
	handle.position = point
	preview_root.add_child(handle)

func _add_marker(point: Vector3, normal: Vector3, selected: bool = false) -> void:
	var marker := MeshInstance3D.new()
	var sphere := SphereMesh.new()
	sphere.radius = 0.115 if selected else 0.09
	sphere.height = sphere.radius * 2.0
	sphere.radial_segments = 16
	sphere.rings = 8
	marker.mesh = sphere
	marker.material_override = selected_marker_material if selected else marker_material
	marker.position = point + normal * 0.06
	preview_root.add_child(marker)

func _remember_path() -> void:
	if control_points.is_empty():
		return
	history.append({
		"points": control_points.duplicate(),
		"normals": control_normals.duplicate(),
		"hard_corners": control_hard_corners.duplicate(),
		"angles": control_angles.duplicate(),
		"corner_segments": control_corner_segments.duplicate(),
		"wall_offsets": control_wall_offsets.duplicate(),
		"colliders": control_colliders.duplicate(),
		"collider": path_collider
	})
	if history.size() > 20:
		history.pop_front()

func _undo() -> void:
	_cancel_input()
	if history.is_empty():
		status_label.text = "没有可撤销的路径。"
		return
	var previous: Dictionary = history.pop_back()
	control_points.assign(previous["points"])
	control_normals.assign(previous["normals"])
	control_hard_corners.assign(previous["hard_corners"])
	control_angles.assign(previous["angles"])
	control_corner_segments.assign(previous["corner_segments"])
	control_wall_offsets.assign(previous["wall_offsets"])
	control_colliders.assign(previous["colliders"])
	path_collider = previous["collider"]
	_rebuild_from_controls()
	status_label.text = "已撤销到上一条路径。"

func _clear_path() -> void:
	if pipe_finalized:
		status_label.text = "已完成管道已冻结；请新建下一根管道。"
		return
	_remember_path()
	_cancel_input()
	control_points.clear()
	control_normals.clear()
	control_hard_corners.clear()
	control_angles.clear()
	control_corner_segments.clear()
	control_wall_offsets.clear()
	control_colliders.clear()
	path_points.clear()
	path_normals.clear()
	path_wall_offsets.clear()
	path_collider = null
	_clear_children(pipe_root)
	_clear_children(preview_root)
	stats_label.text = "路径已清除 · 左键重新绘制"
	status_label.text = "已清除；可重新设置起止点或 Paint。"

func _cancel_input() -> void:
	painting = false
	orbiting = false
	dragging_control = false
	dragging_wall_offset = false
	selected_control = -1
	appended_control_on_click = false
	pending_start.clear()
	paint_points.clear()
	paint_normals.clear()
	paint_hard_corners.clear()
	paint_crease_count = 0
	_update_preview(path_points, path_normals)
	_update_control_settings()

func _add_segment() -> void:
	var last_diameter: float = segments[-1]["diameter"]
	segments.append({"end": 1.0, "diameter": last_diameter})
	for i in segments.size():
		segments[i]["end"] = float(i + 1) / float(segments.size())
	_rebuild_segment_rows()
	_generate_pipe()
	status_label.text = "已添加分段；修改各段终点和直径即可变径。"

func _remove_segment(index: int) -> void:
	if segments.size() <= 1:
		return
	segments.remove_at(index)
	segments[-1]["end"] = 1.0
	_rebuild_segment_rows()
	_generate_pipe()

func _on_segment_end_changed(value: float, index: int) -> void:
	if index == segments.size() - 1:
		segments[index]["end"] = 1.0
	else:
		var minimum: float = 0.05 if index == 0 else float(segments[index - 1]["end"]) + 0.05
		var maximum: float = float(segments[index + 1]["end"]) - 0.05
		segments[index]["end"] = clampf(value / 100.0, minimum, maximum)
	_generate_pipe()

func _on_segment_diameter_changed(value: float, index: int) -> void:
	segments[index]["diameter"] = value
	_generate_pipe()

func _on_radial_changed(value: float) -> void:
	radial_segments = int(value)
	_generate_pipe()

func _on_texture_size_changed(value: float) -> void:
	texture_world_size = value
	_generate_pipe()

func _on_clearance_changed(value: float) -> void:
	clearance = value
	_generate_pipe()

func _clear_children(node: Node) -> void:
	for child in node.get_children():
		node.remove_child(child)
		child.queue_free()

func _create_demo_pipe() -> void:
	var start := {
		"position": Vector3(-1.45, 0.65, 1.201),
		"normal": Vector3.BACK,
		"collider": main_box
	}
	var finish := {
		"position": Vector3(0.95, 3.05, 1.201),
		"normal": Vector3.BACK,
		"collider": main_box
	}
	var solved: Dictionary = SurfaceSolver.find_path(start, finish)
	if solved.has("error"):
		status_label.text = "示例生成失败：" + solved["error"]
		print(status_label.text)
		return
	segments = [
		{"end": 0.34, "diameter": 0.30},
		{"end": 0.68, "diameter": 0.48},
		{"end": 1.0, "diameter": 0.34}
	]
	_rebuild_segment_rows()
	_commit_path(solved["points"], solved["normals"], main_box, "示例：起止点自动寻路")
	print("PIPE_PCG_READY")
