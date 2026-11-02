@tool
extends VBoxContainer

var plugin: EditorPlugin
var selected: PCGSurfaceComponent
var selected_label: Label
var angle_spin: SpinBox
var scale_spin: SpinBox
var transition_toggle: CheckButton
var thickness_spin: SpinBox
var curvature_spin: SpinBox
var density_option: OptionButton
var lod_option: OptionButton
var deferred_toggle: CheckButton
var merge_selected_button: Button
var merge_all_button: Button
var delete_button: Button

func setup(controller: EditorPlugin, definitions: Array[PCGComponentDefinition]) -> void:
	plugin = controller
	size_flags_horizontal = Control.SIZE_EXPAND_FILL
	add_theme_constant_override("separation", 8)
	var title := Label.new()
	title.text = "表面组件"
	title.add_theme_font_size_override("font_size", 20)
	add_child(title)
	_add_hint("先创建主体，再从组件库拖入视口。\n松开创建；选中后可拖动与合并。")
	if plugin.has_method("open_asset_tasks"):
		_add_button("资产任务", plugin.open_asset_tasks)
	_add_heading("附着主体")
	_add_button("创建平面墙", plugin.create_host.bind(0))
	_add_button("创建圆柱", plugin.create_host.bind(1))
	_add_button("创建半球圆柱", plugin.create_host.bind(2))
	_add_heading("组件库")
	for definition in definitions:
		var card := Button.new()
		card.text = "%s  %.2f × %.2f m" % [definition.display_name, definition.size.x, definition.size.y]
		card.tooltip_text = "按住并拖到可吸附主体上"
		card.button_down.connect(plugin.begin_component_drag.bind(definition.id))
		card.button_up.connect(plugin.finish_component_drag)
		add_child(card)
	_add_heading("选中组件")
	selected_label = Label.new()
	selected_label.text = "未选择"
	selected_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	add_child(selected_label)
	angle_spin = _spin("法线倾角", -90.0, 90.0, 1.0, plugin.set_attachment_angle)
	scale_spin = _spin("等比缩放", 0.1, 2.0, 0.05, plugin.set_user_scale)
	transition_toggle = CheckButton.new()
	transition_toggle.text = "主体包裹过渡"
	transition_toggle.toggled.connect(plugin.set_transition_enabled)
	add_child(transition_toggle)
	thickness_spin = _spin("过渡厚度", 0.02, 1.0, 0.01, plugin.set_transition_thickness)
	curvature_spin = _spin("过渡弧度", -1.0, 1.0, 0.05, plugin.set_transition_curvature)
	density_option = _options("过渡精度", ["25%", "50%", "100%", "200%"], plugin.set_transition_density)
	lod_option = _options("LOD", ["LOD 0", "LOD 1", "LOD 2"], plugin.set_transition_lod)
	_add_heading("融合操作")
	deferred_toggle = CheckButton.new()
	deferred_toggle.text = "后合并编辑（轻量预览）"
	deferred_toggle.toggled.connect(plugin.set_deferred_fusion)
	add_child(deferred_toggle)
	merge_selected_button = _add_button("合并选中组件", plugin.merge_selected)
	merge_all_button = _add_button("全部合并", plugin.merge_all)
	delete_button = _add_button("删除选中组件", plugin.delete_selected)

func _add_heading(text: String) -> void:
	var separator := HSeparator.new()
	add_child(separator)
	var label := Label.new()
	label.text = text
	label.add_theme_font_size_override("font_size", 16)
	add_child(label)

func _add_hint(text: String) -> void:
	var label := Label.new()
	label.text = text
	label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	label.add_theme_font_size_override("font_size", 12)
	add_child(label)

func _add_button(text: String, callback: Callable) -> Button:
	var button := Button.new()
	button.text = text
	button.pressed.connect(callback)
	add_child(button)
	return button

func _spin(label_text: String, minimum: float, maximum: float, step: float, callback: Callable) -> SpinBox:
	var row := HBoxContainer.new()
	add_child(row)
	var label := Label.new()
	label.text = label_text
	label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(label)
	var spin := SpinBox.new()
	spin.min_value = minimum
	spin.max_value = maximum
	spin.step = step
	spin.value_changed.connect(callback)
	row.add_child(spin)
	return spin

func _options(label_text: String, items: Array, callback: Callable) -> OptionButton:
	var row := HBoxContainer.new()
	add_child(row)
	var label := Label.new()
	label.text = label_text
	label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(label)
	var option := OptionButton.new()
	for item in items:
		option.add_item(item)
	option.item_selected.connect(callback)
	row.add_child(option)
	return option

func set_selected(component: PCGSurfaceComponent) -> void:
	selected = component
	if selected_label == null:
		return
	if component == null:
		selected_label.text = "未选择"
		merge_selected_button.disabled = true
		delete_button.disabled = true
		return
	selected_label.text = "%s\n%s\n尺寸 %d%% · 倾角 %.0f°" % [component.definition.display_name, component.wall.display_name, roundi(component.current_scale * 100.0), component.attachment_angle_degrees]
	angle_spin.set_value_no_signal(component.attachment_angle_degrees)
	scale_spin.set_value_no_signal(component.user_scale)
	transition_toggle.set_pressed_no_signal(component.transition_enabled)
	thickness_spin.set_value_no_signal(component.effective_transition_thickness())
	curvature_spin.set_value_no_signal(component.transition_curvature)
	density_option.select([0.25, 0.5, 1.0, 2.0].find(component.transition_density))
	lod_option.select(component.transition_lod)
	merge_selected_button.disabled = not component.wall.preview_mode
	delete_button.disabled = false
