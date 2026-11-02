@tool
extends Window

# v0.15 L0 资产任务与精度规范窗口：基于共享 PCGAssetTask / PCGAssetTaskStore，
# 负责任务的新建、表单编辑、校验展示、保存与重开。

signal tasks_changed

const DEFAULT_TASKS_DIRECTORY := "res://assets/tasks"
const TASK_CLASS_NAME := "PCGAssetTask"
const STORE_CLASS_NAME := "PCGAssetTaskStore"
const SHARED_DIR_CANDIDATES := [
	"res://addons/pcg_shared",
]

var tasks_directory := DEFAULT_TASKS_DIRECTORY
var task_script: GDScript
var store_script: GDScript
var store: RefCounted
var tasks: Array = []
var current_task: Resource
var resolved := false

var task_option: OptionButton
var new_button: Button
var save_button: Button
var reload_button: Button
var status_label: Label
var validation_list: ItemList
var fields: Dictionary = {}  # StringName -> Control（键与 PCGAssetTask 字段同名）

func _ready() -> void:
	title = "L0 资产任务与精度规范"
	close_requested.connect(hide)
	min_size = Vector2i(620, 640)
	_build_ui()
	_resolve_shared_scripts()

func open_tasks(directory: String = "") -> void:
	if not directory.is_empty():
		tasks_directory = directory
	if store != null:
		store.directory = tasks_directory
	if not resolved:
		_resolve_shared_scripts()
	if not resolved:
		if status_label != null:
			status_label.text = "共享资产任务 API 缺失：未找到 PCGAssetTask / PCGAssetTaskStore"
		return
	refresh_task_list()
	if current_task == null:
		_new_task()
	popup_centered(Vector2i(640, 700))

func refresh_task_list() -> void:
	if store == null:
		return
	tasks = store.list_tasks(tasks_directory)
	task_option.clear()
	for task in tasks:
		task_option.add_item("%s  %s" % [String(task.task_id), String(task.display_name)])
	_select_current_in_option()

func set_field_value(field: StringName, value: Variant) -> void:
	var control: Control = fields.get(field)
	if control == null:
		return
	if control is LineEdit:
		control.text = _joined(value)
	elif control is TextEdit:
		control.text = _joined(value)
	elif control is SpinBox:
		control.set_value_no_signal(float(value))
	elif control is OptionButton:
		_select_option_by_value(control, value)
	elif control is HBoxContainer and control.has_meta("vec3"):
		var vec := value as Vector3
		var spins := _vec3_spins(control)
		spins[0].set_value_no_signal(vec.x)
		spins[1].set_value_no_signal(vec.y)
		spins[2].set_value_no_signal(vec.z)
	_read_form_into_task()
	_refresh_validation()

func get_field_value(field: StringName) -> Variant:
	var control: Control = fields.get(field)
	if control == null:
		return null
	if control is LineEdit:
		return control.text
	if control is TextEdit:
		return control.text
	if control is SpinBox:
		return control.value
	if control is OptionButton:
		return control.get_selected_metadata()
	if control is HBoxContainer and control.has_meta("vec3"):
		var spins := _vec3_spins(control)
		return Vector3(spins[0].value, spins[1].value, spins[2].value)
	return null

func _resolve_shared_scripts() -> void:
	if task_script != null and store_script != null:
		resolved = true
		return
	task_script = _find_shared_script(TASK_CLASS_NAME)
	store_script = _find_shared_script(STORE_CLASS_NAME)
	resolved = task_script != null and store_script != null
	if resolved:
		store = store_script.new()
		if store != null and tasks_directory != DEFAULT_TASKS_DIRECTORY:
			store.directory = tasks_directory

static func _find_shared_script(global_class: String) -> GDScript:
	for entry in ProjectSettings.get_global_class_list():
		if String(entry.get("class", "")) == global_class:
			var script: GDScript = load(String(entry.get("path", "")))
			if script != null and script.can_instantiate():
				return script
	for dir_path in SHARED_DIR_CANDIDATES:
		var script := _scan_dir_for_class(dir_path, global_class)
		if script != null:
			return script
	return null

static func _scan_dir_for_class(dir_path: String, global_class: String) -> GDScript:
	var dir := DirAccess.open(dir_path)
	if dir == null:
		return null
	for file_name in dir.get_files():
		if not file_name.ends_with(".gd"):
			continue
		var full_path := dir_path.path_join(file_name)
		var file := FileAccess.open(full_path, FileAccess.READ)
		if file == null:
			continue
		if _has_class_declaration(file.get_as_text(), global_class):
			var script: GDScript = load(full_path)
			if script != null and script.can_instantiate():
				return script
	return null

static func _has_class_declaration(source: String, global_class: String) -> bool:
	for line in source.split("\n"):
		if line.strip_edges() == "class_name " + global_class:
			return true
	return false

func _build_ui() -> void:
	var root := VBoxContainer.new()
	root.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	root.add_theme_constant_override("separation", 6)
	add_child(root)
	var top_row := HBoxContainer.new()
	root.add_child(top_row)
	task_option = OptionButton.new()
	task_option.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	task_option.item_selected.connect(_on_task_selected)
	top_row.add_child(task_option)
	new_button = _small_button(top_row, "新建", _on_new_pressed)
	save_button = _small_button(top_row, "保存", _on_save_pressed)
	reload_button = _small_button(top_row, "重开", _on_reload_pressed)

	var scroll := ScrollContainer.new()
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	scroll.custom_minimum_size = Vector2(0, 380)
	root.add_child(scroll)
	var form := VBoxContainer.new()
	form.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	form.add_theme_constant_override("separation", 4)
	scroll.add_child(form)

	_line_field(form, "任务 ID", &"task_id")
	_line_field(form, "显示名称", &"display_name")
	_option_field(form, "类别", &"category",
		["door", "window", "support", "sign", "decoration", "stairs", "pipe", "host", "other"])
	_text_field(form, "用途", &"purpose")
	_line_field(form, "风格标签（逗号分隔）", &"style_tags")
	_line_field(form, "参考链接（逗号分隔）", &"reference_urls")
	_option_field(form, "生产者", &"producer", ["human", "ai", "external", "procedural"])
	_line_field(form, "来源工具", &"source_tool")
	_text_field(form, "来源提示词", &"source_prompt")
	_line_field(form, "来源种子", &"source_seed")
	_vec3_field(form, "目标尺寸 (m)", &"target_size", 0.0, 1000.0, 0.05)
	_vec3_field(form, "尺寸下限 (m)", &"size_min", 0.0, 1000.0, 0.05)
	_vec3_field(form, "尺寸上限 (m)", &"size_max", 0.0, 1000.0, 0.05)
	_option_field(form, "精度档位", &"precision_tier", ["near", "mid", "far"])
	_option_field(form, "UV 策略", &"uv_policy", ["world_scale", "texel_density", "custom"])
	_option_field(form, "碰撞策略", &"collision_policy", ["none", "box", "convex", "concave"])
	_spin_field(form, "LOD0 三角预算", &"tri_budget", 0.0, 100000000.0, 100.0)
	_spin_field(form, "LOD1 三角预算", &"lod1_budget", 0.0, 100000000.0, 100.0)
	_spin_field(form, "LOD2 三角预算", &"lod2_budget", 0.0, 100000000.0, 100.0)
	_spin_field(form, "贴图尺寸", &"texture_size", 16.0, 16384.0, 1.0)
	_spin_field(form, "材质预算", &"material_budget", 0.0, 256.0, 1.0)
	_line_field(form, "原点约定", &"origin_convention")
	_vec3_field(form, "外法线轴", &"outward_axis", -1.0, 1.0, 0.05)
	_vec3_field(form, "上方向轴", &"up_axis", -1.0, 1.0, 0.05)
	_spin_field(form, "根部嵌入", &"root_embed", -1.0, 1.0, 0.01)
	_text_field(form, "接口需求", &"interface_requirements")
	_text_field(form, "可变外观", &"variable_appearance")
	_text_field(form, "固定特征", &"fixed_features")
	_text_field(form, "禁止特征", &"prohibited_features")
	_spin_field(form, "变体数量", &"variant_count", 1.0, 256.0, 1.0)
	_line_field(form, "候选引用（逗号分隔）", &"candidate_refs")
	_option_field(form, "状态", &"status",
		["draft", "assigned", "candidate", "pending_acceptance", "accepted", "rejected"])
	_text_field(form, "验收备注", &"acceptance_notes")

	var validation_heading := Label.new()
	validation_heading.text = "校验结果"
	validation_heading.add_theme_font_size_override("font_size", 15)
	root.add_child(validation_heading)
	validation_list = ItemList.new()
	validation_list.custom_minimum_size = Vector2(0, 72)
	root.add_child(validation_list)
	status_label = Label.new()
	status_label.text = ""
	status_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	root.add_child(status_label)

func _small_button(parent: Control, text: String, callback: Callable) -> Button:
	var button := Button.new()
	button.text = text
	button.pressed.connect(callback)
	parent.add_child(button)
	return button

func _field_row(parent: Control, label_text: String) -> HBoxContainer:
	var row := HBoxContainer.new()
	parent.add_child(row)
	var label := Label.new()
	label.text = label_text
	label.custom_minimum_size = Vector2(150, 0)
	row.add_child(label)
	return row

func _line_field(parent: Control, label_text: String, field: StringName) -> LineEdit:
	var row := _field_row(parent, label_text)
	var edit := LineEdit.new()
	edit.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	edit.text_changed.connect(_on_form_edited)
	row.add_child(edit)
	fields[field] = edit
	return edit

func _text_field(parent: Control, label_text: String, field: StringName) -> TextEdit:
	var row := _field_row(parent, label_text)
	var edit := TextEdit.new()
	edit.custom_minimum_size = Vector2(0, 44)
	edit.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	edit.text_changed.connect(_on_form_edited)
	row.add_child(edit)
	fields[field] = edit
	return edit

func _spin_field(parent: Control, label_text: String, field: StringName, minimum: float, maximum: float, step: float) -> SpinBox:
	var row := _field_row(parent, label_text)
	var spin := SpinBox.new()
	spin.min_value = minimum
	spin.max_value = maximum
	spin.step = step
	spin.value_changed.connect(_on_form_edited)
	row.add_child(spin)
	fields[field] = spin
	return spin

func _option_field(parent: Control, label_text: String, field: StringName, values: Array) -> OptionButton:
	var row := _field_row(parent, label_text)
	var option := OptionButton.new()
	option.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	for value in values:
		option.add_item(String(value))
		option.set_item_metadata(option.item_count - 1, StringName(value))
	option.item_selected.connect(_on_form_edited)
	row.add_child(option)
	fields[field] = option
	return option

func _vec3_field(parent: Control, label_text: String, field: StringName, minimum: float, maximum: float, step: float) -> HBoxContainer:
	var row := _field_row(parent, label_text)
	var box := HBoxContainer.new()
	box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	box.set_meta("vec3", true)
	for axis in 3:
		var spin := SpinBox.new()
		spin.min_value = minimum
		spin.max_value = maximum
		spin.step = step
		spin.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		spin.value_changed.connect(_on_form_edited)
		box.add_child(spin)
	row.add_child(box)
	fields[field] = box
	return box

func _on_form_edited(_arg: Variant = null) -> void:
	_read_form_into_task()
	_refresh_validation()

func _read_form_into_task() -> void:
	if current_task == null:
		return
	for field in fields:
		if not _task_has_field(String(field)):
			continue
		var control: Control = fields[field]
		var value: Variant = _read_control(control)
		match String(field):
			"task_id", "category", "producer", "precision_tier", "uv_policy", "collision_policy", "status":
				current_task.set(String(field), StringName(str(value).strip_edges()))
			"style_tags", "reference_urls", "candidate_refs":
				var packed := PackedStringArray()
				for part in str(value).split(",", false):
					packed.append(part.strip_edges())
				current_task.set(String(field), packed)
			"tri_budget", "lod1_budget", "lod2_budget", "texture_size", "material_budget", "variant_count":
				current_task.set(String(field), int(value))
			_:
				current_task.set(String(field), value)

func _task_has_field(field: String) -> bool:
	if current_task == null:
		return false
	for property in current_task.get_property_list():
		if String(property.get("name", "")) == field:
			return true
	return false

func _read_control(control: Control) -> Variant:
	if control is LineEdit:
		return control.text
	if control is TextEdit:
		return control.text
	if control is SpinBox:
		return control.value
	if control is OptionButton:
		return control.get_selected_metadata()
	if control is HBoxContainer and control.has_meta("vec3"):
		var spins := _vec3_spins(control)
		return Vector3(spins[0].value, spins[1].value, spins[2].value)
	return null

func _write_form_from_task() -> void:
	if current_task == null:
		return
	for field in fields:
		if not _task_has_field(String(field)):
			continue
		var control: Control = fields[field]
		var value: Variant = current_task.get(String(field))
		if control is LineEdit:
			control.text = _joined(value)
		elif control is TextEdit:
			control.text = _joined(value)
		elif control is SpinBox:
			control.set_value_no_signal(float(value))
		elif control is OptionButton:
			_select_option_by_value(control, value)
		elif control is HBoxContainer and control.has_meta("vec3"):
			var vec: Vector3 = value
			var spins := _vec3_spins(control)
			spins[0].set_value_no_signal(vec.x)
			spins[1].set_value_no_signal(vec.y)
			spins[2].set_value_no_signal(vec.z)

static func _joined(value: Variant) -> String:
	if value is PackedStringArray:
		return ", ".join(Array(value))
	return str(value)

func _select_option_by_value(option: OptionButton, value: Variant) -> void:
	var target := str(value)
	for index in option.item_count:
		if str(option.get_item_metadata(index)) == target:
			option.select(index)
			return
	option.select(0)

func _vec3_spins(box: HBoxContainer) -> Array:
	var spins: Array = []
	for child in box.get_children():
		if child is SpinBox:
			spins.append(child)
	return spins

func _needs_assignment_validation() -> bool:
	if current_task == null:
		return false
	# 非草稿状态即视为对外流转/分配，按完整规范校验。
	return StringName(current_task.status) != &"draft"

func _refresh_validation() -> void:
	validation_list.clear()
	if current_task == null or task_script == null:
		save_button.disabled = true
		return
	var errors: Array = current_task.validation_errors(_needs_assignment_validation())
	for error in errors:
		validation_list.add_item(String(error))
	save_button.disabled = not errors.is_empty()

func _new_task() -> void:
	if task_script == null:
		return
	current_task = task_script.new()
	_write_form_from_task()
	task_option.select(-1)
	_refresh_validation()
	status_label.text = "新建草稿任务"

func _on_new_pressed() -> void:
	_new_task()

func _on_task_selected(index: int) -> void:
	if index < 0 or index >= tasks.size():
		return
	current_task = tasks[index]
	_write_form_from_task()
	_refresh_validation()
	status_label.text = "已载入 %s" % String(current_task.task_id)

func _on_save_pressed() -> void:
	if current_task == null or store == null:
		return
	_read_form_into_task()
	_refresh_validation()
	if save_button.disabled:
		status_label.text = "校验未通过，未保存"
		return
	var result: Dictionary = store.save_task(current_task, tasks_directory)
	if result.get("ok", false):
		status_label.text = "已保存: %s" % String(result.get("path", ""))
		refresh_task_list()
		tasks_changed.emit()
	else:
		var details := PackedStringArray()
		for error in result.get("errors", []):
			details.append(String(error))
		status_label.text = "保存失败: %s" % "; ".join(details)

func _on_reload_pressed() -> void:
	# 重开：从磁盘重新载入当前选中任务，丢弃未保存的表单修改。
	if store == null:
		return
	refresh_task_list()
	if current_task == null:
		_new_task()
		return
	var saved := _find_task_by_id(StringName(current_task.task_id))
	if saved == null:
		status_label.text = "磁盘上不存在该任务，保持当前编辑"
		return
	current_task = saved
	_write_form_from_task()
	_refresh_validation()
	status_label.text = "已从磁盘重开 %s" % String(current_task.task_id)

func _find_task_by_id(task_id: StringName) -> Resource:
	for task in tasks:
		if StringName(task.task_id) == task_id:
			return task
	return null

func _select_current_in_option() -> void:
	if current_task == null:
		return
	for index in tasks.size():
		if StringName(tasks[index].task_id) == StringName(current_task.task_id):
			task_option.select(index)
			return
