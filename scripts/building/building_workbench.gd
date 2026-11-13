extends Node3D

const Plan = preload("res://scripts/building/building_plan.gd")
const Footprint = preload("res://scripts/building/building_footprint.gd")
const Catalog = preload("res://scripts/building/building_component_catalog.gd")
const Generator = preload("res://scripts/building/building_generator.gd")
const PlanEditor = preload("res://scripts/building/building_plan_editor.gd")
const Connector = preload("res://scripts/building/skybridge_connector.gd")
const SkybridgeGen = preload("res://scripts/building/skybridge_generator.gd")
const MeshBuildUtil = preload("res://addons/pcg_shared/mesh_build_util.gd")

class FitIconButton extends Button:
	func _draw() -> void:
		var center := size * 0.5
		var color := get_theme_color("font_color")
		for sx in [-1.0, 1.0]:
			for sy in [-1.0, 1.0]:
				var start := center + Vector2(sx, sy) * 9.0
				var direction := -Vector2(sx, sy).normalized()
				var tip := start + direction * 6.0
				var side := Vector2(-direction.y, direction.x) * 2.2
				draw_line(start, tip, color, 1.5, true)
				draw_line(tip, tip - direction * 3.0 + side, color, 1.5, true)
				draw_line(tip, tip - direction * 3.0 - side, color, 1.5, true)

var plan: PCGBuildingPlan
var catalog := PCGBuildingComponentCatalog.new()
var generator := PCGBuildingGenerator.new()
var skybridge_generator := SkybridgeGen.new()
var building_root: Node3D
var ground: MeshInstance3D
var skybridge_root: Node3D
var building_nodes: Dictionary = {}
var selected_id: StringName = &""
var selected_ids: Array[StringName] = []
var selected_bridge_id: StringName = &""
var selected_connector_id: StringName = &""
var selected_node_index: int = -1
var camera: Camera3D
var camera_target := Vector3(0.8, 3.8, 1.0)
var camera_yaw: float = -0.7
var camera_pitch: float = 0.58
var camera_distance: float = 21.0
var orbiting := false
var _last_orbit_position := Vector2.ZERO
var plan_editor: PCGBuildingPlanEditor
var detail_window: Window
var detail_plan_editor: PCGBuildingPlanEditor
var detail_zoom_label: Label
var fusion_button: Button
var status_label: Label
var stats_label: Label
var selected_label: Label
var bridge_info_label: Label
var floors_spin: SpinBox
var floor_height_spin: SpinBox
var seed_spin: SpinBox
var connector_floor_spin: SpinBox
var tension_spin: SpinBox
var node_height_spin: SpinBox
var session: BuildingPlanSession
# 兼容入口：plan/快照/撤销统一经 BuildingPlanSession 的 PCGEditCommandHistory 适配。
var undo_redo: PCGEditCommandHistory
var _drag_before: Dictionary = {}
var _bridge_drag_before: Dictionary = {}
var _last_param_snapshot: Dictionary = {}
var _skybridge_digest: String = ""

func _ready() -> void:
	_build_environment()
	_build_camera()
	catalog.load_from("res://assets/building_components")
	plan = Plan.demo()
	_setup_demo_skybridge()
	session = BuildingPlanSession.new(plan, _on_session_apply)
	undo_redo = session.history
	building_root = Node3D.new()
	building_root.name = "Buildings"
	add_child(building_root)
	_build_ui()
	_update_terrain()
	_sync_plan()
	if not plan.footprints.is_empty():
		_select_footprint(plan.footprints[0].id)
	_update_camera()

func _setup_demo_skybridge() -> void:
	var first := Connector.new()
	first.id = &"conn_l_tower"
	first.building_id = &"house_l"
	first.edge_index = 1
	first.edge_t = 0.5
	first.floor = 1
	var second := Connector.new()
	second.id = &"conn_tower_l"
	second.building_id = &"house_tower"
	second.edge_index = 3
	second.edge_t = 0.5
	second.floor = 1
	plan.connectors.append(first)
	plan.connectors.append(second)
	var made := skybridge_generator.make_bridge(plan, first, second, &"bridge_demo", catalog)
	if made["errors"].is_empty():
		plan.skybridges.append(made["bridge"])

func _build_environment() -> void:
	var world_environment := WorldEnvironment.new()
	var environment := Environment.new()
	environment.background_mode = Environment.BG_COLOR
	environment.background_color = Color("15242c")
	environment.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	environment.ambient_light_color = Color("c5d9df")
	environment.ambient_light_energy = 0.5
	environment.tonemap_mode = Environment.TONE_MAPPER_FILMIC
	world_environment.environment = environment
	add_child(world_environment)
	var sun := DirectionalLight3D.new()
	sun.rotation_degrees = Vector3(-52.0, -32.0, 0.0)
	sun.light_color = Color("ffe2ba")
	sun.light_energy = 1.0
	sun.shadow_enabled = true
	add_child(sun)
	var fill := DirectionalLight3D.new()
	fill.rotation_degrees = Vector3(-28.0, 145.0, 0.0)
	fill.light_color = Color("8bbce0")
	fill.light_energy = 0.3
	add_child(fill)
	ground = MeshInstance3D.new()
	var mesh := BoxMesh.new()
	mesh.size = Vector3(30.0, 0.2, 30.0)
	ground.mesh = mesh
	ground.position.y = -0.12
	ground.material_override = MaterialLibrary.solid(&"building/ground", Color("283c42"), 0.94)
	add_child(ground)

func _build_camera() -> void:
	camera = Camera3D.new()
	camera.fov = 45.0
	camera.near = 0.05
	camera.far = 150.0
	camera.current = true
	add_child(camera)

func _build_ui() -> void:
	var canvas := CanvasLayer.new()
	add_child(canvas)
	var title_panel := PanelContainer.new()
	title_panel.set_anchors_preset(Control.PRESET_TOP_WIDE)
	title_panel.offset_left = 18.0
	title_panel.offset_top = 16.0
	title_panel.offset_right = -18.0
	title_panel.offset_bottom = 94.0
	canvas.add_child(title_panel)
	var title_box := VBoxContainer.new()
	title_panel.add_child(title_box)
	var title := Label.new()
	title.text = "建筑平面工作台 · Floor Plan → Procedural Buildings"
	title.add_theme_font_size_override("font_size", 22)
	title_box.add_child(title)
	status_label = Label.new()
	status_label.text = "拖动左侧平面顶点，建筑、门窗和屋顶构件会同步重建。"
	status_label.add_theme_color_override("font_color", Color("bdd8df"))
	title_box.add_child(status_label)

	var left_panel := PanelContainer.new()
	left_panel.set_anchors_preset(Control.PRESET_LEFT_WIDE)
	left_panel.offset_left = 18.0
	left_panel.offset_top = 112.0
	left_panel.offset_right = 354.0
	left_panel.offset_bottom = -18.0
	canvas.add_child(left_panel)
	var left_margin := MarginContainer.new()
	left_margin.add_theme_constant_override("margin_left", 10)
	left_margin.add_theme_constant_override("margin_right", 10)
	left_margin.add_theme_constant_override("margin_top", 10)
	left_margin.add_theme_constant_override("margin_bottom", 10)
	left_panel.add_child(left_margin)
	var left_scroll := ScrollContainer.new()
	left_margin.add_child(left_scroll)
	var left := VBoxContainer.new()
	left.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	left.add_theme_constant_override("separation", 9)
	left_scroll.add_child(left)
	_add_heading(left, "建筑主体编辑")
	plan_editor = _make_plan_editor()
	left.add_child(plan_editor)
	_install_view_controls(plan_editor)
	_add_hint(left, "滚轮缩放；拖动空白、右键或中键平移。\n坐标吸附到 0.25 m 网格。")
	_button(left, "打开独立细节窗口", _open_detail_window)
	_button(left, "新增面岛 / 建筑", _add_footprint)
	_button(left, "循环切分选中面岛", _split_selected)
	fusion_button = _button(left, "融合选中建筑", _fuse_selected)
	fusion_button.disabled = true
	_button(left, "删除选中面岛", _delete_selected)
	_add_hint(left, "Shift+单击可多选建筑；至少两栋轮廓相交/相接时才能融合。")
	_add_heading(left, "廊桥编辑")
	_button(left, "模式：建筑主体平面编辑", func(): _set_editor_mode(PCGBuildingPlanEditor.InteractionMode.FOOTPRINT,
		"建筑主体平面编辑模式：拖动整栋或顶点；Shift+单击多选。"))
	_button(left, "模式：标注结合点", func(): _set_editor_mode(PCGBuildingPlanEditor.InteractionMode.CONNECTOR,
		"结合点模式：点击建筑立面边缘放置廊桥结合点；点击已有结合点选中后，可用下方“结合点楼层”修改其楼层。"))
	_button(left, "模式：桥节点编辑", func(): _set_editor_mode(PCGBuildingPlanEditor.InteractionMode.BRIDGE_NODE,
		"桥节点模式：拖动路径节点改变走向与弧度；选中节点后可在右侧面板调转弯强度和桥面高度。"))
	connector_floor_spin = _spin_row(left, "结合点楼层", 0.0, 11.0, 1.0)
	connector_floor_spin.value = 1.0
	connector_floor_spin.value_changed.connect(_on_connector_floor_changed)
	_button(left, "生成廊桥（连接两个空闲结合点）", _create_skybridge)
	_button(left, "删除选中廊桥", _delete_selected_bridge)
	bridge_info_label = Label.new()
	bridge_info_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	bridge_info_label.add_theme_color_override("font_color", Color("9fc4ce"))
	bridge_info_label.text = "尚无廊桥。"
	left.add_child(bridge_info_label)
	_add_hint(left, "廊桥按生成数据重建：结合点所在开间的窗口自动避让并重新排布；\n多桥交叉时横截面重叠超过 60% 合并为 cross 结构，否则自动垂直错开（可用节点继续微调）。")
	_add_heading(left, "标准组件库")
	for definition in catalog.definitions:
		_add_hint(left, "%s · %s" % [definition.display_name, _role_name(definition.role)])
	for error in catalog.errors:
		_add_hint(left, error)
	_add_hint(left, "组件由 assets/building_components/*.tres 注册；\n新增资产不需要修改生成器。")

	var right_panel := PanelContainer.new()
	right_panel.set_anchors_preset(Control.PRESET_RIGHT_WIDE)
	right_panel.offset_left = -320.0
	right_panel.offset_top = 112.0
	right_panel.offset_right = -18.0
	right_panel.offset_bottom = -18.0
	canvas.add_child(right_panel)
	var right_margin := MarginContainer.new()
	right_margin.add_theme_constant_override("margin_left", 12)
	right_margin.add_theme_constant_override("margin_right", 12)
	right_margin.add_theme_constant_override("margin_top", 10)
	right_panel.add_child(right_margin)
	var right := VBoxContainer.new()
	right.add_theme_constant_override("separation", 10)
	right_margin.add_child(right)
	_add_heading(right, "建筑参数")
	selected_label = Label.new()
	selected_label.add_theme_color_override("font_color", Color("f4cf83"))
	right.add_child(selected_label)
	floors_spin = _spin_row(right, "楼层数", 1.0, 12.0, 1.0)
	floors_spin.value_changed.connect(_on_floors_changed)
	floor_height_spin = _spin_row(right, "层高（米）", 2.0, 5.0, 0.05)
	floor_height_spin.value_changed.connect(_on_floor_height_changed)
	seed_spin = _spin_row(right, "细节种子", 0.0, 9999.0, 1.0)
	seed_spin.value_changed.connect(_on_seed_changed)
	_add_hint(right, "种子修改后立即自动重建，无需应用按钮。\n每栋建筑使用独立随机流，不影响其他建筑。")
	_add_heading(right, "桥节点编辑")
	tension_spin = _spin_row(right, "转弯强度", 0.0, 3.0, 0.05)
	tension_spin.value_changed.connect(_on_tension_changed)
	node_height_spin = _spin_row(right, "桥面高度（米）", 0.0, 40.0, 0.05)
	node_height_spin.value_changed.connect(_on_node_height_changed)
	tension_spin.editable = false
	node_height_spin.editable = false
	_add_hint(right, "先在顶视图进入“桥节点编辑”模式并点击节点。\n转弯强度 1 为自然穿过，0 为圆角驻停，>1 加强转弯；\n自动错开的抬升量也保留在节点高度中，可手动覆盖。")
	_add_heading(right, "生成统计")
	stats_label = Label.new()
	stats_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	stats_label.add_theme_color_override("font_color", Color("a9c6ce"))
	right.add_child(stats_label)
	_add_heading(right, "操作")
	_button(right, "切换斜坡演示", _toggle_terrain)
	_button(right, "修复选中建筑", _repair_selected)
	_button(right, "撤销 / 重做", func(): status_label.text = "快捷键：⌘/Ctrl+Z 撤销，Shift+⌘/Ctrl+Z 重做。")
	_button(right, "重置视角 (F)", _reset_camera)
	_button(right, "返回表面组件示例", func(): get_tree().change_scene_to_file("res://scenes/main.tscn"))
	_add_hint(right, "右键拖动环绕 · 滚轮缩放\n⌘/Ctrl+Z 撤销 · Delete 删除")

func _make_plan_editor() -> PCGBuildingPlanEditor:
	var editor := PlanEditor.new()
	editor.footprint_selected.connect(_select_footprint)
	editor.vertex_drag_started.connect(_on_vertex_drag_started)
	editor.footprint_edited.connect(_on_plan_edited)
	editor.footprint_move_started.connect(_on_building_move_started)
	editor.footprint_moved.connect(_on_building_moved)
	editor.footprint_move_finished.connect(_on_building_move_finished)
	editor.vertex_drag_finished.connect(_on_vertex_drag_finished)
	editor.connector_placed.connect(_on_connector_placed)
	editor.connector_selected.connect(_on_connector_selected)
	editor.bridge_node_selected.connect(_on_bridge_node_selected)
	editor.bridge_node_moved.connect(_on_bridge_node_moved)
	editor.bridge_node_drag_finished.connect(_on_bridge_node_drag_finished)
	editor.zoom_changed.connect(_on_detail_zoom_changed)
	return editor

func _install_view_controls(editor: PCGBuildingPlanEditor) -> void:
	var controls := HBoxContainer.new()
	controls.add_theme_constant_override("separation", 3)
	controls.set_anchors_preset(Control.PRESET_TOP_RIGHT)
	controls.offset_left = -112.0
	controls.offset_top = 8.0
	controls.offset_right = -8.0
	controls.offset_bottom = 40.0
	controls.z_index = 20
	editor.add_child(controls)
	_view_button(controls, "−", func(): editor.zoom_at(editor.size * 0.5, 1.0 / 1.2))
	_view_button(controls, "+", func(): editor.zoom_at(editor.size * 0.5, 1.2))
	controls.get_child(0).tooltip_text = "缩小视图"
	controls.get_child(1).tooltip_text = "放大视图"
	var fit := FitIconButton.new()
	fit.custom_minimum_size = Vector2(32.0, 30.0)
	fit.focus_mode = Control.FOCUS_NONE
	fit.tooltip_text = "适配全部建筑、结合点与廊桥"
	fit.pressed.connect(editor.fit_to_content)
	controls.add_child(fit)

func _view_button(parent: HBoxContainer, text: String, callback: Callable) -> void:
	var button := Button.new()
	button.text = text
	button.focus_mode = Control.FOCUS_NONE
	button.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	button.pressed.connect(callback)
	parent.add_child(button)

func _open_detail_window() -> void:
	if detail_window == null:
		detail_window = Window.new()
		detail_window.hide()
		detail_window.title = "建筑平面细节 · 共享编辑"
		detail_window.force_native = true
		detail_window.size = Vector2i(1000, 800)
		detail_window.position = get_window().position + Vector2i(80, 60)
		detail_window.close_requested.connect(detail_window.hide)
		add_child(detail_window)
		var margin := MarginContainer.new()
		margin.set_anchors_preset(Control.PRESET_FULL_RECT)
		margin.add_theme_constant_override("margin_left", 12)
		margin.add_theme_constant_override("margin_right", 12)
		margin.add_theme_constant_override("margin_top", 12)
		margin.add_theme_constant_override("margin_bottom", 12)
		detail_window.add_child(margin)
		var content := VBoxContainer.new()
		content.add_theme_constant_override("separation", 10)
		margin.add_child(content)
		detail_zoom_label = Label.new()
		detail_zoom_label.add_theme_color_override("font_color", Color("9fc4ce"))
		content.add_child(detail_zoom_label)
		detail_plan_editor = _make_plan_editor()
		detail_plan_editor.size_flags_vertical = Control.SIZE_EXPAND_FILL
		content.add_child(detail_plan_editor)
		_install_view_controls(detail_plan_editor)
		var hint := Label.new()
		hint.text = "滚轮以光标为中心缩放；拖动空白、右键或中键平移。与原顶视图共享编辑数据。"
		content.add_child(hint)
	detail_plan_editor.set_plan(plan)
	detail_plan_editor.set_selection(selected_ids, selected_id)
	detail_plan_editor.set_interaction_mode(plan_editor.interaction_mode)
	detail_plan_editor.selected_bridge_id = plan_editor.selected_bridge_id
	detail_plan_editor.selected_node_index = plan_editor.selected_node_index
	detail_plan_editor.fit_to_content()
	detail_window.show()
	status_label.text = "已打开独立细节窗口；两个视图共享同一平面与编辑历史。"

func _on_detail_zoom_changed(value: float) -> void:
	if detail_zoom_label != null:
		detail_zoom_label.text = "缩放 %d%% · 25%%～800%%" % roundi(value * 100.0)

func _spin_row(parent: VBoxContainer, text: String, minimum: float, maximum: float, step: float) -> SpinBox:
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
	row.add_child(spin)
	return spin

func _button(parent: VBoxContainer, text: String, callback: Callable) -> Button:
	var button := Button.new()
	button.text = text
	button.focus_mode = Control.FOCUS_NONE
	button.pressed.connect(callback)
	parent.add_child(button)
	return button

func _add_heading(parent: VBoxContainer, text: String) -> void:
	var separator := HSeparator.new()
	parent.add_child(separator)
	var label := Label.new()
	label.text = text
	label.add_theme_font_size_override("font_size", 19)
	parent.add_child(label)

func _add_hint(parent: VBoxContainer, text: String) -> void:
	var label := Label.new()
	label.text = text
	label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	label.add_theme_font_size_override("font_size", 13)
	label.add_theme_color_override("font_color", Color("91acb5"))
	parent.add_child(label)

func _sync_plan() -> bool:
	var errors := plan.validation_errors()
	errors.append_array(catalog.errors)
	if not errors.is_empty():
		status_label.text = "生成已停止：%s" % "; ".join(errors)
		return false
	var valid: Dictionary = {}
	for footprint in plan.footprints:
		valid[footprint.id] = true
		var signature := PCGCanonicalSerializer.hash_document(plan.facade_signature_for(footprint.id))
		if not building_nodes.has(footprint.id):
			_rebuild_building(footprint.id)
		elif building_nodes[footprint.id].get_meta("semantic_digest", "") != signature:
			_rebuild_building(footprint.id)
	for id in building_nodes.keys():
		if not valid.has(id):
			var node: Node3D = building_nodes[id]
			building_root.remove_child(node)
			node.queue_free()
			building_nodes.erase(id)
	_sync_skybridges()
	plan_editor.set_plan(plan)
	if detail_plan_editor != null:
		detail_plan_editor.set_plan(plan)
	_update_stats()
	_update_fusion_button()
	return true

func _rebuild_building(id: StringName) -> bool:
	var footprint := plan.get_footprint(id)
	if footprint == null:
		return false
	var result := generator.build_building(footprint, plan.master_seed, catalog,
		plan.footprints, plan.facade_exclusions_for(id), plan, plan.connectors_for_building(id))
	if not result["errors"].is_empty():
		status_label.text = "保留上一份有效网格：%s" % "; ".join(result["errors"])
		return false
	var building: Node3D = result["root"]
	if building_nodes.has(id):
		var old: Node3D = building_nodes[id]
		building_root.remove_child(old)
		old.queue_free()
	building_root.add_child(building)
	building_nodes[id] = building
	_update_stats()
	return true

func _sync_skybridges() -> bool:
	# 交叉错开属于求解阶段：先按当前路径重算 auto_lift，再取摘要，保证 digest 与求解结果一致。
	skybridge_generator.resolve_crossings(plan, catalog)
	var digest := PCGCanonicalSerializer.hash_document(
		skybridge_generator.network_semantic_data(plan))
	if digest == _skybridge_digest and skybridge_root != null:
		return true
	var result := skybridge_generator.build_network(plan, catalog)
	if not result["errors"].is_empty():
		status_label.text = "廊桥保留上一份有效网格：%s" % "; ".join(result["errors"])
		return false
	_skybridge_digest = digest
	if skybridge_root != null:
		remove_child(skybridge_root)
		skybridge_root.queue_free()
	skybridge_root = result["root"]
	add_child(skybridge_root)
	_update_bridge_info(result)
	_update_stats()
	return true

func _update_bridge_info(result: Dictionary) -> void:
	if bridge_info_label == null:
		return
	if plan.skybridges.is_empty():
		bridge_info_label.text = "尚无廊桥。"
		return
	var lines: PackedStringArray = []
	var merged: Array = result.get("merged", [])
	var lifted: Array = result.get("lifted", [])
	var junctions: Array = result.get("junctions", [])
	for bridge in plan.skybridges:
		if bridge == null:
			continue
		var tags: PackedStringArray = []
		if merged.has(String(bridge.id)):
			tags.append("已合并 cross 结构")
		if lifted.has(String(bridge.id)):
			tags.append("已自动错开 %+0.2fm" % bridge.auto_lift)
		lines.append("%s：%s → %s%s" % [
			bridge.id, bridge.connector_a, bridge.connector_b,
			("（%s）" % "、".join(tags)) if not tags.is_empty() else ""])
	if junctions.size() > 0:
		lines.append("交叉合并结构：%d 处" % junctions.size())
	bridge_info_label.text = "\n".join(lines)

func _set_editor_mode(mode: int, hint: String) -> void:
	plan_editor.set_interaction_mode(mode)
	if detail_plan_editor != null:
		detail_plan_editor.set_interaction_mode(mode)
	if mode != PCGBuildingPlanEditor.InteractionMode.BRIDGE_NODE:
		selected_bridge_id = &""
		selected_node_index = -1
		_update_node_editor()
	status_label.text = hint

func _on_connector_selected(connector_id: StringName) -> void:
	selected_connector_id = connector_id
	var connector := plan.get_connector(connector_id)
	if connector == null:
		return
	connector_floor_spin.set_value_no_signal(connector.floor)
	status_label.text = "已选中结合点 %s（%s · F%d）；修改“结合点楼层”即可调整其高度。" % [
		connector.id, connector.building_id, connector.floor]

func _on_connector_floor_changed(value: float) -> void:
	var connector := plan.get_connector(selected_connector_id)
	if connector == null:
		return
	var footprint := plan.get_footprint(connector.building_id)
	if footprint == null:
		return
	var before := _plan_snapshot()
	connector.floor = clampi(int(value), 0, footprint.floors - 1)
	# 已连接的廊桥端点随结合点楼层移动，中间节点保持在两端中点。
	var anchor := connector.anchor(footprint)
	var end_position: Vector3 = anchor["position"] - anchor["outward"] * SkybridgeGen.RECESS_DEPTH
	for bridge in plan.skybridges:
		if bridge == null:
			continue
		var index := -1
		if bridge.connector_a == connector.id:
			index = 0
		elif bridge.connector_b == connector.id:
			index = bridge.nodes.size() - 1
		if index >= 0 and bridge.nodes.size() >= 3:
			bridge.set_node_position(index, end_position)
			var first: Vector3 = bridge.nodes[0]["position"]
			var last: Vector3 = bridge.nodes[bridge.nodes.size() - 1]["position"]
			bridge.set_node_position(bridge.nodes.size() / 2, (first + last) * 0.5)
	_sync_plan()
	_register_plan_action("修改结合点楼层", before, _plan_snapshot(), &"connector_floor:%s" % connector.id)
	status_label.text = "结合点 %s 楼层已改为 F%d；门洞与已连接廊桥已联动。" % [connector.id, connector.floor]

func _on_connector_placed(building_id: StringName, edge_index: int, edge_t: float) -> void:
	var footprint := plan.get_footprint(building_id)
	if footprint == null:
		return
	var before := _plan_snapshot()
	var connector := Connector.new()
	connector.building_id = building_id
	connector.edge_index = edge_index
	connector.edge_t = edge_t
	connector.floor = clampi(int(connector_floor_spin.value), 0, footprint.floors - 1)
	var index := plan.connectors.size() + 1
	connector.id = &"conn_%d" % index
	while plan.get_connector(connector.id) != null:
		index += 1
		connector.id = &"conn_%d" % index
	plan.connectors.append(connector)
	selected_connector_id = &""
	_sync_plan()
	_register_plan_action("标注廊桥结合点", before, _plan_snapshot())
	status_label.text = "已在 %s 边缘标注结合点 %s（F%d）；再标注一个结合点即可生成廊桥。" % [
		building_id, connector.id, connector.floor]

func _create_skybridge() -> void:
	var used: Dictionary = {}
	for bridge in plan.skybridges:
		if bridge != null:
			used[bridge.connector_a] = true
			used[bridge.connector_b] = true
	var free: Array[PCGSkybridgeConnector] = []
	for connector in plan.connectors:
		if connector != null and not used.has(connector.id):
			free.append(connector)
	if free.size() < 2:
		status_label.text = "需要两个尚未连接的结合点；请先在“标注结合点”模式下放置。"
		return
	var before := _plan_snapshot()
	var index := plan.skybridges.size() + 1
	var bridge_id := &"bridge_%d" % index
	while plan.get_skybridge(bridge_id) != null:
		index += 1
		bridge_id = &"bridge_%d" % index
	var made := skybridge_generator.make_bridge(plan, free[0], free[1], bridge_id, catalog)
	if not made["errors"].is_empty():
		status_label.text = "生成失败：%s" % "; ".join(made["errors"])
		return
	plan.skybridges.append(made["bridge"])
	_sync_plan()
	_register_plan_action("生成廊桥", before, _plan_snapshot())
	plan_editor.selected_bridge_id = bridge_id
	plan_editor.queue_redraw()
	if detail_plan_editor != null:
		detail_plan_editor.selected_bridge_id = bridge_id
		detail_plan_editor.queue_redraw()
	status_label.text = "已生成廊桥 %s：%s ↔ %s；立面窗口已自动避让，可进入桥节点编辑模式调整弧度。" % [
		bridge_id, free[0].id, free[1].id]

func _delete_selected_bridge() -> void:
	var bridge_id := plan_editor.selected_bridge_id
	var bridge := plan.get_skybridge(bridge_id)
	if bridge == null:
		status_label.text = "请先在顶视图点击要选中的廊桥（桥节点编辑模式）。"
		return
	var before := _plan_snapshot()
	plan.skybridges.erase(bridge)
	# 级联删除两端结合点：门洞与门套由结合点驱动，删除后主体自动重建恢复墙面。
	for connector_id in [bridge.connector_a, bridge.connector_b]:
		var still_used := false
		for other in plan.skybridges:
			if other != null and (other.connector_a == connector_id or other.connector_b == connector_id):
				still_used = true
				break
		if not still_used:
			var connector := plan.get_connector(connector_id)
			if connector != null:
				if connector.id == selected_connector_id:
					selected_connector_id = &""
				plan.connectors.erase(connector)
	plan_editor.selected_bridge_id = &""
	plan_editor.selected_node_index = -1
	if detail_plan_editor != null:
		detail_plan_editor.selected_bridge_id = &""
		detail_plan_editor.selected_node_index = -1
		detail_plan_editor.queue_redraw()
	selected_bridge_id = &""
	selected_node_index = -1
	_update_node_editor()
	_sync_plan()
	_register_plan_action("删除廊桥", before, _plan_snapshot())
	status_label.text = "已删除廊桥 %s 及其两端入口（结合点），主体墙面随之恢复，可通过撤销找回。" % bridge_id

func _on_bridge_node_selected(bridge_id: StringName, node_index: int) -> void:
	selected_bridge_id = bridge_id
	selected_node_index = node_index
	plan_editor.selected_bridge_id = bridge_id
	plan_editor.selected_node_index = node_index
	plan_editor.queue_redraw()
	if detail_plan_editor != null:
		detail_plan_editor.selected_bridge_id = bridge_id
		detail_plan_editor.selected_node_index = node_index
		detail_plan_editor.queue_redraw()
	_bridge_drag_before = _bridge_snapshot(plan.get_skybridge(bridge_id))
	_update_node_editor()

func _on_bridge_node_moved(bridge_id: StringName, node_index: int, position: Vector3) -> void:
	var bridge := plan.get_skybridge(bridge_id)
	if bridge == null:
		return
	bridge.set_node_position(node_index, position)
	_sync_skybridges()
	plan_editor.set_plan(plan)
	if detail_plan_editor != null:
		detail_plan_editor.set_plan(plan)

func _on_bridge_node_drag_finished(bridge_id: StringName) -> void:
	var bridge := plan.get_skybridge(bridge_id)
	if bridge == null:
		_bridge_drag_before = {}
		return
	var after := _bridge_snapshot(bridge)
	_register_bridge_action("拖动廊桥节点", bridge_id, _bridge_drag_before, after, &"drag_bridge_node:%s" % bridge_id)
	_bridge_drag_before = {}
	status_label.text = "廊桥节点已更新；路径、交叉合并与错开已重新求解。"

func _on_tension_changed(value: float) -> void:
	var bridge := plan.get_skybridge(selected_bridge_id)
	if bridge == null or selected_node_index < 0:
		return
	var before := _bridge_snapshot(bridge)
	bridge.set_node_tension(selected_node_index, value)
	_after_bridge_edit("调整转弯强度", bridge, before)

func _on_node_height_changed(value: float) -> void:
	var bridge := plan.get_skybridge(selected_bridge_id)
	if bridge == null or selected_node_index < 0:
		return
	var before := _bridge_snapshot(bridge)
	var position: Vector3 = bridge.nodes[selected_node_index].get("position", Vector3.ZERO)
	position.y = value
	bridge.set_node_position(selected_node_index, position)
	_after_bridge_edit("调整桥面高度", bridge, before)

func _after_bridge_edit(name: String, bridge: PCGSkybridgeDefinition, before: Dictionary) -> void:
	var after := _bridge_snapshot(bridge)
	_register_bridge_action(name, bridge.id, before, after)
	_sync_skybridges()
	plan_editor.set_plan(plan)
	if detail_plan_editor != null:
		detail_plan_editor.set_plan(plan)

func _update_node_editor() -> void:
	var bridge := plan.get_skybridge(selected_bridge_id)
	var enabled := bridge != null and selected_node_index >= 0
	tension_spin.editable = enabled
	node_height_spin.editable = enabled
	if not enabled:
		return
	tension_spin.set_value_no_signal(bridge.node_tension(selected_node_index))
	var position: Vector3 = bridge.nodes[selected_node_index].get("position", Vector3.ZERO)
	node_height_spin.set_value_no_signal(position.y)

func _repair_selected() -> void:
	var footprint := plan.get_footprint(selected_id)
	if footprint == null:
		status_label.text = "请先选择需要修复的建筑。"
		return
	if _rebuild_building(selected_id):
		var building: Node3D = building_nodes[selected_id]
		var rejected := int(building.get_meta("rejected_decorations", 0))
		status_label.text = "已修复选中建筑：重排门窗并避开占用冲突；阻止 %d 处立面组件放置。" % rejected

func _select_footprint(id: StringName, additive: bool = false) -> void:
	if additive:
		if selected_ids.has(id):
			selected_ids.erase(id)
		else:
			selected_ids.append(id)
		selected_id = id if selected_ids.has(id) else (selected_ids[-1] if not selected_ids.is_empty() else &"")
	else:
		selected_ids.assign([id] if not id.is_empty() else [])
		selected_id = id
	plan_editor.set_selection(selected_ids, selected_id)
	if detail_plan_editor != null:
		detail_plan_editor.set_selection(selected_ids, selected_id)
	_update_inspector()
	_update_fusion_button()

func _update_inspector() -> void:
	var footprint := plan.get_footprint(selected_id)
	var enabled := footprint != null
	floors_spin.editable = enabled
	floor_height_spin.editable = enabled
	seed_spin.editable = enabled
	if not enabled:
		selected_label.text = "未选择建筑"
		_last_param_snapshot = {}
		return
	selected_label.text = "%s · %.2f m 高" % [footprint.id, footprint.height()]
	floors_spin.set_value_no_signal(footprint.floors)
	floor_height_spin.set_value_no_signal(footprint.floor_height)
	seed_spin.set_value_no_signal(footprint.seed)
	_last_param_snapshot = _footprint_snapshot(footprint)

func _update_stats() -> void:
	if stats_label == null:
		return
	var components := 0
	var triangles := 0
	for node in building_nodes.values():
		components += int(node.get_meta("component_count", 0))
		triangles += int(node.get_meta("triangle_count", 0))
	var bridges := 0
	var junctions := 0
	if skybridge_root != null:
		for child in skybridge_root.get_children():
			match String(child.get_meta("bridge_role", "")):
				"skybridge":
					bridges += 1
					triangles += MeshBuildUtil.triangle_count(child.mesh)
				"skybridge_junction":
					junctions += 1
					triangles += MeshBuildUtil.triangle_count(child.mesh)
	stats_label.text = "%d 个面岛 / 建筑\n%d 个标准组件实例\n%d 条廊桥 · %d 个交叉合并结构\n约 %d 个三角形（含实例）" % [
		building_nodes.size(), components, bridges, junctions, triangles]

func _on_building_move_started(id: StringName) -> void:
	if not plan_editor.selected_ids.has(id):
		_select_footprint(id)
	_drag_before = _footprint_snapshot(plan.get_footprint(id))

func _on_building_moved(id: StringName, delta: Vector2) -> void:
	var footprint := plan.get_footprint(id)
	if footprint == null:
		return
	var polygon := footprint.polygon.duplicate()
	for index in polygon.size():
		polygon[index] += delta
	footprint.polygon = polygon
	_sync_plan()
	status_label.text = "建筑已平移 %.2f, %.2f m；主体与连接关系已同步。" % [delta.x, delta.y]

func _on_building_move_finished(id: StringName) -> void:
	var after := _footprint_snapshot(plan.get_footprint(id))
	_register_footprint_action("平移建筑", id, _drag_before, after, &"move_building:%s" % id)
	_drag_before = {}

func _on_vertex_drag_started(id: StringName) -> void:
	_select_footprint(id)
	_drag_before = _footprint_snapshot(plan.get_footprint(id))

func _on_plan_edited(id: StringName) -> void:
	_rebuild_building(id)
	_update_inspector()

func _on_vertex_drag_finished(id: StringName) -> void:
	var after := _footprint_snapshot(plan.get_footprint(id))
	_register_footprint_action("编辑平面顶点", id, _drag_before, after, &"drag_vertex:%s" % id)
	_drag_before = {}
	status_label.text = "平面已更新；主体、立面和屋顶组件已联动。"

func _on_floors_changed(value: float) -> void:
	_change_parameter("floors", int(value))

func _on_floor_height_changed(value: float) -> void:
	_change_parameter("floor_height", value)

func _on_seed_changed(value: float) -> void:
	_change_parameter("seed", int(value))

func _change_parameter(property: StringName, value: Variant) -> void:
	var footprint := plan.get_footprint(selected_id)
	if footprint == null:
		return
	var before := _last_param_snapshot.duplicate(true)
	footprint.set(property, value)
	var after := _footprint_snapshot(footprint)
	_register_footprint_action("修改建筑参数", selected_id, before, after, &"param:%s:%s" % [selected_id, property])
	_last_param_snapshot = after
	_rebuild_building(selected_id)
	_update_inspector()

func _add_footprint() -> void:
	var before := _plan_snapshot()
	var footprint := Footprint.new()
	var index := plan.footprints.size() + 1
	footprint.id = &"house_%d" % index
	while plan.get_footprint(footprint.id) != null:
		index += 1
		footprint.id = &"house_%d" % index
	var random := PCGDeterministicRng.create_stream(plan.master_seed, {
		"building": footprint.id, "purpose": &"layout",
	})
	footprint.polygon = _density_aware_shape(random, footprint.id)
	footprint.floors = random.randi_range(2, 6)
	footprint.seed = random.randi_range(0, 9999)
	var palette: Array[Color] = [Color("c39a78"), Color("a8b1a0"), Color("b98065"), Color("b7a48b"), Color("91a7ad")]
	footprint.wall_color = palette[random.pick_index(palette.size())]
	footprint.wall_material_id = &"building/wall/%s" % footprint.id
	plan.footprints.append(footprint)
	selected_id = footprint.id
	_sync_plan()
	_select_footprint(selected_id)
	_register_plan_action("新增建筑", before, _plan_snapshot())
	status_label.text = "已在低密度区域新增 %s：%d 层；位置、轮廓和参数可复现。" % [footprint.id, footprint.floors]

func _density_aware_shape(random: PCGRandomStream, id: StringName) -> PackedVector2Array:
	return FootprintGeometryOps.density_aware_shape(random, _plan_polygons())

func _plan_polygons() -> Array:
	var polygons: Array = []
	for footprint in plan.footprints:
		if footprint != null:
			polygons.append(footprint.normalized_polygon())
	return polygons

func _density_at(point: Vector2) -> float:
	return FootprintGeometryOps.density_at(point, _plan_polygons())

func _shape_overlaps(shape: PackedVector2Array, point: Vector2) -> bool:
	return FootprintGeometryOps.shape_overlaps(shape, point, _plan_polygons())

func _fuse_selected() -> void:
	if selected_ids.size() < 2:
		status_label.text = "请先按住 Shift 选择至少两栋建筑。"
		return
	if not _can_fuse_selection():
		status_label.text = "选中的建筑必须轮廓相交或相接，才能融合。"
		return
	var targets: Array[PCGBuildingFootprint] = []
	for id in selected_ids:
		var item := plan.get_footprint(id)
		if item == null:
			return
		if not plan.connectors_for_building(id).is_empty():
			status_label.text = "%s 仍有廊桥结合点；请先移除连接，再融合。" % id
			return
		targets.append(item)
	var footprint := plan.get_footprint(selected_id)
	var others: Array = []
	var removed: Array[StringName] = []
	for other in targets:
		if other.id == footprint.id:
			continue
		others.append(other.normalized_polygon())
		footprint.floors = maxi(footprint.floors, other.floors)
		removed.append(other.id)
	var merged := FootprintGeometryOps.fuse(footprint.normalized_polygon(), others)
	var before := _plan_snapshot()
	footprint.polygon = merged
	for other in targets:
		if other.id != footprint.id:
			plan.footprints.erase(other)
	selected_ids.assign([footprint.id])
	_sync_plan()
	_select_footprint(footprint.id)
	_register_plan_action("融合选中建筑", before, _plan_snapshot())
	status_label.text = "已融合 %d 栋建筑到 %s；可继续平移、切分或撤销。" % [removed.size() + 1, footprint.id]

func _can_fuse_selection() -> bool:
	if selected_ids.size() < 2:
		return false
	var primary := plan.get_footprint(selected_id)
	if primary == null:
		return false
	var others: Array = []
	for id in selected_ids:
		if id == selected_id:
			continue
		var other := plan.get_footprint(id)
		if other == null:
			return false
		others.append(other.normalized_polygon())
	return FootprintGeometryOps.can_fuse(primary.normalized_polygon(), others)

func _update_fusion_button() -> void:
	if fusion_button == null:
		return
	fusion_button.disabled = not _can_fuse_selection()
	fusion_button.tooltip_text = "选择至少两栋相交或相接的建筑后可用。" if fusion_button.disabled else "融合当前选中的建筑，可撤销。"

func _split_selected() -> void:
	var footprint := plan.get_footprint(selected_id)
	if footprint == null:
		return
	if not plan.connectors_for_building(selected_id).is_empty():
		status_label.text = "%s 仍有廊桥结合点；切分会改变立面边序号，请先移除连接，再切分。" % selected_id
		return
	var parts := FootprintGeometryOps.split_centered(footprint.normalized_polygon())
	var first: PackedVector2Array = parts["first"]
	var second: PackedVector2Array = parts["second"]
	if first.is_empty() or second.is_empty():
		status_label.text = "当前轮廓无法沿中心轴切分，请先调整平面。"
		return
	var before := _plan_snapshot()
	footprint.polygon = first
	var addition := footprint.duplicate(true) as PCGBuildingFootprint
	addition.id = &"%s_b" % footprint.id
	var suffix := 2
	while plan.get_footprint(addition.id) != null:
		addition.id = &"%s_b%d" % [footprint.id, suffix]
		suffix += 1
	addition.polygon = second
	plan.footprints.append(addition)
	_sync_plan()
	_select_footprint(addition.id)
	_register_plan_action("切分面岛", before, _plan_snapshot())
	status_label.text = "已沿中心轴切分为两个独立面岛，原有 ID 保留给第一部分。"

func _delete_selected() -> void:
	var footprint := plan.get_footprint(selected_id)
	if footprint == null:
		return
	var before := _plan_snapshot()
	plan.footprints.erase(footprint)
	var orphan_connectors: Array = []
	for connector in plan.connectors:
		if connector != null and connector.building_id == footprint.id:
			orphan_connectors.append(connector)
	for connector in orphan_connectors:
		plan.connectors.erase(connector)
	var dead_bridges: Array = []
	for bridge in plan.skybridges:
		if bridge != null and (
				not plan.get_connector(bridge.connector_a)
				or not plan.get_connector(bridge.connector_b)):
			dead_bridges.append(bridge)
	for bridge in dead_bridges:
		plan.skybridges.erase(bridge)
	selected_id = plan.footprints[0].id if not plan.footprints.is_empty() else &""
	_sync_plan()
	_select_footprint(selected_id)
	_register_plan_action("删除面岛", before, _plan_snapshot())
	status_label.text = "已删除选中面岛及其结合点与廊桥，可通过撤销恢复。"

func _footprint_snapshot(footprint: PCGBuildingFootprint) -> Dictionary:
	if footprint == null:
		return {}
	return {
		"polygon": footprint.polygon.duplicate(), "floors": footprint.floors,
		"floor_height": footprint.floor_height, "seed": footprint.seed,
		"wall_color": footprint.wall_color, "wall_material_id": footprint.wall_material_id,
	}

func _register_footprint_action(name: String, id: StringName, before: Dictionary, after: Dictionary, merge_key: StringName = &"") -> void:
	session.submit_footprint_action(name, id, before, after, merge_key)

func _bridge_snapshot(bridge: PCGSkybridgeDefinition) -> Dictionary:
	if bridge == null:
		return {}
	return {
		"nodes": bridge.nodes.duplicate(true),
		"auto_lift": bridge.auto_lift,
		"width": bridge.width,
		"height": bridge.height,
		"color": bridge.color,
	}

func _register_bridge_action(name: String, id: StringName, before: Dictionary, after: Dictionary, merge_key: StringName = &"") -> void:
	session.submit_bridge_action(name, id, before, after, merge_key)

func _plan_snapshot() -> Dictionary:
	return session.snapshot()

func _register_plan_action(name: String, before: Dictionary, after: Dictionary, merge_key: StringName = &"") -> void:
	session.submit_plan_action(name, before, after, merge_key)

# 会话历史应用入口：plan 数据已由 BuildingPlanSession 恢复，这里只做 UI/场景同步。
func _on_session_apply(command: PCGEditCommand, use_after: bool) -> void:
	match StringName(command.scope.get("op", &"")):
		&"plan":
			if plan.get_footprint(selected_id) == null:
				selected_id = plan.footprints[0].id if not plan.footprints.is_empty() else &""
			if plan.get_skybridge(selected_bridge_id) == null:
				selected_bridge_id = &""
				selected_node_index = -1
			_sync_plan()
			_select_footprint(selected_id)
			_update_node_editor()
		&"footprint":
			_rebuild_building(command.target_id)
			_select_footprint(command.target_id)
		&"bridge":
			_sync_skybridges()
			plan_editor.set_plan(plan)
			if detail_plan_editor != null:
				detail_plan_editor.set_plan(plan)
			_update_node_editor()
		&"terrain":
			_update_terrain()
			_sync_plan()

func _polygon_bounds(polygon: PackedVector2Array) -> Rect2:
	return FootprintGeometryOps.polygon_bounds(polygon)

func _plan_bounds() -> Rect2:
	return FootprintGeometryOps.plan_bounds(_plan_polygons())

func _role_name(role: int) -> String:
	return ["立面窗", "入口", "屋顶边线", "墙角", "立面出挑", "屋顶设备", "屋顶晾衣", "窗外晾衣", "小阳台", "双门入口", "廊桥"][role]

func _input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed and not event.echo \
			and event.keycode == KEY_Z and (event.ctrl_pressed or event.meta_pressed):
		if event.shift_pressed:
			undo_redo.redo()
		else:
			undo_redo.undo()
		status_label.text = "已恢复历史状态；仅重建发生变化的建筑。"
		get_viewport().set_input_as_handled()
	elif event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_RIGHT:
		var was_orbiting := orbiting
		if event.pressed:
			orbiting = not plan_editor.get_global_rect().has_point(event.position)
			_last_orbit_position = event.position
		else:
			orbiting = false
		if was_orbiting or orbiting:
			get_viewport().set_input_as_handled()
	elif event is InputEventMouseMotion and orbiting:
		var delta: Vector2 = event.position - _last_orbit_position
		_last_orbit_position = event.position
		camera_yaw -= delta.x * 0.006
		camera_pitch = clampf(camera_pitch + delta.y * 0.005, 0.12, 1.35)
		_update_camera()
		get_viewport().set_input_as_handled()

func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventMouseButton:
		if event.button_index == MOUSE_BUTTON_WHEEL_UP and event.pressed:
			camera_distance = maxf(7.0, camera_distance * 0.9)
			_update_camera()
		elif event.button_index == MOUSE_BUTTON_WHEEL_DOWN and event.pressed:
			camera_distance = minf(42.0, camera_distance * 1.1)
			_update_camera()
	elif event is InputEventKey and event.pressed and not event.echo:
		if event.keycode == KEY_F:
			_reset_camera()
		elif event.keycode == KEY_DELETE:
			_delete_selected()

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

func _toggle_terrain() -> void:
	var before := plan.terrain_slope
	var after := Vector2.ZERO if not before.is_zero_approx() else Vector2(0.14, 0.08)
	_set_terrain_slope(after)
	session.submit_terrain_action("切换斜坡地形", before, after)
	status_label.text = "已切换为水平地面。" if after.is_zero_approx() else "斜坡演示：移动建筑会自动更新标高、基础和廊桥连接。"

func _set_terrain_slope(value: Vector2) -> void:
	plan.terrain_slope = value
	_update_terrain()
	_sync_plan()

func _update_terrain() -> void:
	if ground == null:
		return
	var normal := Vector3(-plan.terrain_slope.x, 1.0, -plan.terrain_slope.y).normalized()
	ground.quaternion = Quaternion(Vector3.UP, normal)

func _reset_camera() -> void:
	camera_target = Vector3(0.8, 3.8, 1.0)
	camera_yaw = -0.7
	camera_pitch = 0.58
	camera_distance = 21.0
	_update_camera()

func _exit_tree() -> void:
	undo_redo = null
	session = null
