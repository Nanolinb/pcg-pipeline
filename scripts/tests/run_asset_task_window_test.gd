extends SceneTree

# v0.15 L0 资产任务窗口 UI/集成测试（headless）。
# 运行: Godot --headless --path <根工程> -s scripts/tests/run_asset_task_window_test.gd
# 用真实 Window 控件驱动 addons/surface_components/asset_task_window.gd，
# 覆盖窗口打开、新建、表单填写、校验结果、保存到临时目录、重开恢复、
# 重开后任务列表可见与坏文件不静默跳过。任一检查失败返回非零退出码。

const WINDOW_SCRIPT_PATH := "res://addons/surface_components/asset_task_window.gd"
const PLUGIN_SCRIPT_PATH := "res://addons/surface_components/editor_plugin.gd"
const DOCK_SCRIPT_PATH := "res://addons/surface_components/dock.gd"
const TEST_DIRECTORY := "user://pcg_asset_task_window_test"

var checks_run := 0
var failures: Array[String] = []
var _window: Window

func _initialize() -> void:
	_main()

func _main() -> void:
	print("ASSET_TASK_BEGIN: asset task window UI/integration checks")
	_check_editor_entry_points()
	_cleanup_directory()
	_window = await _make_window()
	await _check_window_opens()
	await _check_new_task_validation_flow()
	await _check_save_and_reload()
	await _check_reopen_lists_saved_tasks()
	await _check_bad_file_does_not_crash()
	print("ASSET_TASK_CHECKS: %d run, %d failed" % [checks_run, failures.size()])
	_cleanup()
	if failures.is_empty():
		print("ASSET_TASK_RESULT: PASS")
		quit(0)
	else:
		for failure in failures:
			print("ASSET_TASK_RESULT_FAIL: " + failure)
		quit(1)

func _record(ok: bool, name: String, detail: String = "") -> void:
	checks_run += 1
	if ok:
		print("ASSET_TASK_CHECK_PASS: %s%s" % [name, "" if detail.is_empty() else " (" + detail + ")"])
	else:
		failures.append(name + ("" if detail.is_empty() else " (" + detail + ")"))
		print("ASSET_TASK_CHECK_FAIL: %s%s" % [name, "" if detail.is_empty() else " (" + detail + ")"])

func _window_script() -> GDScript:
	var script: GDScript = load(WINDOW_SCRIPT_PATH)
	if script == null:
		_record(false, "asset_task_window.gd compiles", WINDOW_SCRIPT_PATH)
	return script

func _make_window() -> Window:
	var script := _window_script()
	if script == null:
		return null
	var window: Window = script.new()
	root.add_child(window)
	await process_frame
	if not window.is_inside_tree():
		_record(false, "window enters scene tree")
	return window

func _check_editor_entry_points() -> void:
	var plugin_script: GDScript = load(PLUGIN_SCRIPT_PATH)
	_record(plugin_script != null and plugin_script.can_instantiate(), "editor_plugin.gd compiles with asset task integration", PLUGIN_SCRIPT_PATH)
	if plugin_script != null:
		var has_entry := false
		for method in plugin_script.get_script_method_list():
			if String(method.get("name", "")) == "open_asset_tasks":
				has_entry = true
				break
		_record(has_entry, "editor_plugin.gd exposes open_asset_tasks()")
	var dock_script: GDScript = load(DOCK_SCRIPT_PATH)
	_record(dock_script != null and dock_script.get_source_code().contains("资产任务"), "dock.gd adds 资产任务 button", DOCK_SCRIPT_PATH)

func _check_window_opens() -> void:
	if _window == null:
		_record(false, "window opens: script missing")
		return
	_record(_window.title == "L0 资产任务与精度规范", "window title is 规范标题", _window.title)
	_window.open_tasks(TEST_DIRECTORY)
	if not _window.resolved:
		_record(false, "shared API resolved (PCGAssetTask/PCGAssetTaskStore)")
		return
	_record(_window.store != null, "shared PCGAssetTaskStore instance created")
	_record(_window.task_option != null and _window.new_button != null
		and _window.save_button != null and _window.reload_button != null
		and _window.validation_list != null, "task selector/new/save/reload/validation controls exist")
	var required := ["task_id", "display_name", "category", "purpose", "producer",
		"source_tool", "source_prompt", "source_seed", "target_size", "size_min", "size_max",
		"precision_tier", "uv_policy", "collision_policy", "candidate_refs", "tri_budget",
		"lod1_budget", "lod2_budget", "texture_size",
		"material_budget", "interface_requirements", "status", "variant_count"]
	var missing := PackedStringArray()
	for field in required:
		if not _window.fields.has(StringName(field)):
			missing.append(field)
	_record(missing.is_empty(), "form covers required task fields", ", ".join(missing))
	_record(_window.visible, "window popup visible after open_tasks")
	_record(_window.task_option.item_count == 0, "empty task directory lists zero tasks")

func _check_new_task_validation_flow() -> void:
	if _window == null or not _window.resolved:
		_record(false, "new/validation flow skipped (window missing shared API)")
		return
	_window._on_new_pressed()
	_record(_window.current_task != null, "新建 creates a draft PCGAssetTask")
	_record(StringName(_window.current_task.status) == &"draft", "new task starts as draft")
	_window.set_field_value(&"status", &"assigned")
	_record(_window.validation_list.item_count > 0, "blank task shows validation errors when assigned")
	_record(_window.save_button.disabled, "save blocked while validation errors exist")
	_window.set_field_value(&"status", &"draft")
	_fill_valid_form()
	_record(_window.validation_list.item_count == 0, "complete form passes draft validation")
	_record(not _window.save_button.disabled, "save enabled after draft validation passes")
	_window.set_field_value(&"status", &"assigned")
	_record(_window.validation_list.item_count == 0, "complete AI task passes assignment validation", "status=assigned")
	_window.set_field_value(&"status", &"draft")

func _fill_valid_form() -> void:
	_window.set_field_value(&"task_id", "task_ui_arch_door")
	_window.set_field_value(&"display_name", "拱形门")
	_window.set_field_value(&"category", &"door")
	_window.set_field_value(&"purpose", "可通行门洞，嵌入门框组件")
	_window.set_field_value(&"style_tags", "industrial, rust")
	_window.set_field_value(&"reference_urls", "https://example.com/arch_door")
	_window.set_field_value(&"producer", &"ai")
	_window.set_field_value(&"source_tool", "kimi-agent")
	_window.set_field_value(&"source_prompt", "工业风拱形金属门")
	_window.set_field_value(&"source_seed", "seed-42")
	_window.set_field_value(&"target_size", Vector3(1.2, 2.4, 0.3))
	_window.set_field_value(&"size_min", Vector3(0.8, 2.0, 0.2))
	_window.set_field_value(&"size_max", Vector3(2.0, 3.0, 0.5))
	_window.set_field_value(&"precision_tier", &"near")
	_window.set_field_value(&"uv_policy", &"texel_density")
	_window.set_field_value(&"collision_policy", &"convex")
	_window.set_field_value(&"candidate_refs", "res://assets/tasks/draft_door_a, res://assets/tasks/draft_door_b")
	_window.set_field_value(&"tri_budget", 8000)
	_window.set_field_value(&"lod1_budget", 4000)
	_window.set_field_value(&"lod2_budget", 1500)
	_window.set_field_value(&"texture_size", 512)
	_window.set_field_value(&"material_budget", 3)
	_window.set_field_value(&"origin_convention", "root_center")
	_window.set_field_value(&"outward_axis", Vector3(0.0, 0.0, 1.0))
	_window.set_field_value(&"up_axis", Vector3(0.0, 1.0, 0.0))
	_window.set_field_value(&"root_embed", 0.12)
	_window.set_field_value(&"interface_requirements", "需要 1.0m 通行净空，铰链接口两枚")
	_window.set_field_value(&"variant_count", 2)

func _check_save_and_reload() -> void:
	if _window == null or not _window.resolved or _window.current_task == null:
		_record(false, "save/reload flow skipped (no current task)")
		return
	_window._on_save_pressed()
	_record(_window.status_label.text.begins_with("已保存"), "保存成功状态反馈", _window.status_label.text)
	var dir := DirAccess.open(TEST_DIRECTORY)
	_record(dir != null and not dir.get_files().is_empty(), "task file written to temp directory", TEST_DIRECTORY)
	var listed: Array = _window.store.list_tasks(TEST_DIRECTORY)
	_record(listed.size() == 1, "store lists one saved task", "count=%d" % listed.size())
	if listed.size() == 1:
		var saved: Resource = listed[0]
		_record(StringName(saved.task_id) == &"task_ui_arch_door"
			and int(saved.tri_budget) == 8000 and int(saved.lod1_budget) == 4000
			and int(saved.lod2_budget) == 1500 and int(saved.texture_size) == 512,
			"saved task round-trips budgets and texture size")
		_record(String(saved.purpose) == "可通行门洞，嵌入门框组件"
			and String(saved.interface_requirements) == "需要 1.0m 通行净空，铰链接口两枚",
			"saved task round-trips purpose and interface requirements")
		_record(StringName(saved.uv_policy) == &"texel_density"
			and StringName(saved.collision_policy) == &"convex",
			"saved task round-trips uv_policy and collision_policy")
		_record(saved.candidate_refs is PackedStringArray
			and saved.candidate_refs.size() == 2
			and String(saved.candidate_refs[0]) == "res://assets/tasks/draft_door_a"
			and String(saved.candidate_refs[1]) == "res://assets/tasks/draft_door_b",
			"saved task round-trips candidate_refs")
		_window.set_field_value(&"display_name", "未保存的篡改")
		_window.set_field_value(&"candidate_refs", "res://assets/tasks/forged")
		_window._on_reload_pressed()
		_record(String(_window.get_field_value(&"display_name")) == "拱形门", "重开 restores saved values and discards edits")
		_record(String(_window.get_field_value(&"candidate_refs")) == "res://assets/tasks/draft_door_a, res://assets/tasks/draft_door_b",
			"重开 restores candidate_refs and discards edits")
		_record(String(_window.current_task.display_name) == "拱形门", "重开 reloads task object from disk")
	# 再存第二个任务，验证列表增长。
	_window._on_new_pressed()
	_window.set_field_value(&"task_id", "task_ui_pipe_valve")
	_window.set_field_value(&"display_name", "管道阀")
	_window.set_field_value(&"purpose", "管道截断阀外观")
	_window.set_field_value(&"category", &"pipe")
	_window.set_field_value(&"producer", &"human")
	_window.set_field_value(&"size_min", Vector3(0.2, 0.2, 0.2))
	_window.set_field_value(&"size_max", Vector3(0.6, 0.6, 0.6))
	_window.set_field_value(&"target_size", Vector3(0.4, 0.4, 0.4))
	_window.set_field_value(&"tri_budget", 3000)
	_window.set_field_value(&"lod1_budget", 1500)
	_window.set_field_value(&"lod2_budget", 600)
	_window.set_field_value(&"texture_size", 256)
	_window.set_field_value(&"material_budget", 1)
	_window.set_field_value(&"interface_requirements", "法兰接口 DN50")
	_window._on_save_pressed()
	_record(_window.store.list_tasks(TEST_DIRECTORY).size() == 2, "second task grows store listing", "count=%d" % _window.store.list_tasks(TEST_DIRECTORY).size())

func _check_reopen_lists_saved_tasks() -> void:
	if _window == null or not _window.resolved:
		_record(false, "reopen listing skipped (window missing shared API)")
		return
	var second: Window = await _make_window()
	if second == null:
		_record(false, "second window instance created")
		return
	second.open_tasks(TEST_DIRECTORY)
	_record(second.task_option.item_count == 2, "reopened window lists both saved tasks", "items=%d" % second.task_option.item_count)
	second.hide()
	second.queue_free()

func _check_bad_file_does_not_crash() -> void:
	if _window == null or not _window.resolved:
		_record(false, "bad file check skipped (window missing shared API)")
		return
	var bad_path := TEST_DIRECTORY + "/broken_task.json"
	var file := FileAccess.open(bad_path, FileAccess.WRITE)
	_record(file != null, "bad task file written")
	if file != null:
		file.store_string("{ not valid json")
		file.close()
	_window.refresh_task_list()
	var still_valid := 0
	for task in _window.tasks:
		if StringName(task.task_id) == &"task_ui_arch_door" or StringName(task.task_id) == &"task_ui_pipe_valve":
			still_valid += 1
	_record(still_valid == 2, "bad file does not silently drop valid tasks", "valid=%d" % still_valid)

func _cleanup_directory() -> void:
	var dir := DirAccess.open(TEST_DIRECTORY)
	if dir == null:
		return
	for file_name in dir.get_files():
		dir.remove(file_name)
	DirAccess.open("user://").remove("pcg_asset_task_window_test")

func _cleanup() -> void:
	_cleanup_directory()
	if _window != null and is_instance_valid(_window):
		_window.queue_free()
