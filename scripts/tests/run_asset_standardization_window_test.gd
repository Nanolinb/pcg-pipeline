extends SceneTree

# v0.16 L1 资产标准化窗口 UI/集成测试（headless）。
# 运行: Godot --headless --path <根工程> -s scripts/tests/run_asset_standardization_window_test.gd
# 用真实 Window 控件驱动 addons/surface_components/asset_standardization_window.gd，
# 覆盖窗口打开、问题网格验收拦截（开放/零面积/非流形/翻转/UV/根部）、
# 路径加载（Mesh/PackedScene）、校准、三主体试装与负例、白盒/碰撞/LOD、
# 发布与重载核对。任一检查失败返回非零退出码。

const WINDOW_SCRIPT_PATH := "res://addons/surface_components/asset_standardization_window.gd"
const PLUGIN_SCRIPT_PATH := "res://addons/surface_components/editor_plugin.gd"
const DOCK_SCRIPT_PATH := "res://addons/surface_components/dock.gd"
const TASK_DIR := "user://pcg_l1_standardization_test/tasks"
const PUBLISH_DIR := "user://pcg_l1_standardization_test/published"
const TEMP_DIR := "user://pcg_l1_standardization_test"
const CAPTURE_DIR := "res://reports/release_verification/v0.16.0"

var checks_run := 0
var failures: Array[String] = []
var _window: Window
var _capture_mode := false


func _initialize() -> void:
	_capture_mode = "--capture" in OS.get_cmdline_user_args() \
		and DisplayServer.get_name() != "headless"
	print("L1_STD_CAPTURE_MODE: %s" % ("ON" if _capture_mode else "OFF"))
	_main()


## 可选 --capture：非 headless 下把真实视口存为 PNG 到
## reports/release_verification/v0.16.0/，日志打印 CAPTURE 路径。
## 不改变任何断言与流程。
func _capture(tag: String) -> void:
	if not _capture_mode:
		return
	await process_frame
	await process_frame
	var image := root.get_texture().get_image()
	var path := CAPTURE_DIR + "/" + tag + ".png"
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(CAPTURE_DIR))
	if image.save_png(ProjectSettings.globalize_path(path)) == OK:
		print("CAPTURE: %s" % ProjectSettings.globalize_path(path))
	else:
		_record(false, "capture saved %s" % tag, path)


func _main() -> void:
	print("L1_STD_BEGIN: asset standardization window UI/integration checks")
	_check_editor_entry_points()
	_cleanup()
	_window = await _make_window()
	await _check_window_opens_and_task_selection()
	await _check_scroll_layout_at_small_size()
	await _check_problem_meshes_blocked()
	await _check_load_from_path()
	await _check_valid_crate_full_flow()
	await _check_calibration()
	await _check_trial_fit_hosts()
	await _check_fit_negative_cases()
	await _check_whitebox_collision_lod()
	await _check_publish_and_reload()
	await _check_publish_requires_task()
	print("L1_STD_CHECKS: %d run, %d failed" % [checks_run, failures.size()])
	_cleanup()
	if failures.is_empty():
		print("L1_STD_RESULT: PASS")
		quit(0)
	else:
		for failure in failures:
			print("L1_STD_RESULT_FAIL: " + failure)
		quit(1)


func _record(ok: bool, name: String, detail: String = "") -> void:
	checks_run += 1
	if ok:
		print("L1_STD_CHECK_PASS: %s%s" % [name, "" if detail.is_empty() else " (" + detail + ")"])
	else:
		failures.append(name + ("" if detail.is_empty() else " (" + detail + ")"))
		print("L1_STD_CHECK_FAIL: %s%s" % [name, "" if detail.is_empty() else " (" + detail + ")"])


func _window_script() -> GDScript:
	var script: GDScript = load(WINDOW_SCRIPT_PATH)
	if script == null:
		_record(false, "asset_standardization_window.gd compiles", WINDOW_SCRIPT_PATH)
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


# ---------------------------------------------------------------------------
# 测试资产构造

# 封闭盒体；outward=true 时按 Godot 顺时针正面绕序（有向体积为负），
# 否则整体反转（翻转面/错误绕序用）。bottom_y 指定 AABB 最低 y（根部位置）。
func _box_mesh(size: Vector3, bottom_y: float, outward := true, with_uv := true) -> ArrayMesh:
	var h := size * 0.5
	var verts := PackedVector3Array([
		Vector3(-h.x, -h.y, -h.z), Vector3(h.x, -h.y, -h.z), Vector3(h.x, h.y, -h.z), Vector3(-h.x, h.y, -h.z),
		Vector3(-h.x, -h.y, h.z), Vector3(h.x, -h.y, h.z), Vector3(h.x, h.y, h.z), Vector3(-h.x, h.y, h.z),
	])
	for i in verts.size():
		verts[i].y += bottom_y + h.y
	# 以 +Z 面 [4,5,6, 4,6,7] 为例是外侧观察逆时针；outward=true 时逐三角形反转为顺时针正面。
	var faces := [
		[0, 3, 2, 0, 2, 1],  # -Z
		[4, 5, 6, 4, 6, 7],  # +Z
		[0, 4, 7, 0, 7, 3],  # -X
		[1, 2, 6, 1, 6, 5],  # +X
		[0, 1, 5, 0, 5, 4],  # -Y
		[3, 7, 6, 3, 6, 2],  # +Y
	]
	var idx := PackedInt32Array()
	for face in faces:
		var tri := [face[0], face[1], face[2], face[3], face[4], face[5]]
		if outward:
			idx.append_array([tri[0], tri[2], tri[1], tri[3], tri[5], tri[4]])
		else:
			idx.append_array(tri)
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = verts
	arrays[Mesh.ARRAY_INDEX] = idx
	if with_uv:
		var uvs := PackedVector2Array()
		for i in verts.size():
			uvs.append(Vector2(0.13 + 0.01 * i, 0.27))
		arrays[Mesh.ARRAY_TEX_UV] = uvs
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	return mesh


# 开放四边形：无 UV、根部悬空（y 从 1 开始），位于 XY 平面 z=0。
func _open_quad_mesh() -> ArrayMesh:
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = PackedVector3Array([
		Vector3(-0.5, 1.0, 0.0), Vector3(0.5, 1.0, 0.0),
		Vector3(0.5, 2.0, 0.0), Vector3(-0.5, 2.0, 0.0),
	])
	arrays[Mesh.ARRAY_INDEX] = PackedInt32Array([0, 1, 2, 0, 2, 3])
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	return mesh


# 零面积面 + 非流形边：边 (0,1) 被 3 个非退化三角形共享；
# 三角形 (2,5,0) 中 v5 与 v2 重合形成零面积面（退化三角不参与边统计）。
func _nonmanifold_mesh() -> ArrayMesh:
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = PackedVector3Array([
		Vector3(-0.5, 0.0, 0.0), Vector3(0.5, 0.0, 0.0), Vector3(0.0, 1.0, 0.0),
		Vector3(0.0, -1.0, 0.0), Vector3(-1.0, 0.5, 0.0), Vector3(0.0, 1.0, 0.0),
	])
	arrays[Mesh.ARRAY_INDEX] = PackedInt32Array([0, 1, 2, 1, 0, 3, 0, 1, 4, 2, 5, 0])
	var uvs := PackedVector2Array()
	for i in 6:
		uvs.append(Vector2(0.11 * (i + 1), 0.31))
	arrays[Mesh.ARRAY_TEX_UV] = uvs
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	return mesh


func _blocking_ids() -> Array:
	return _window._blocking_ids(_window.last_acceptance)


func _dict_to_aabb(raw: Dictionary) -> AABB:
	var min_v: Array = raw.get("min", [])
	var max_v: Array = raw.get("max", [])
	return AABB(Vector3(float(min_v[0]), float(min_v[1]), float(min_v[2])),
		Vector3(float(max_v[0]) - float(min_v[0]), float(max_v[1]) - float(min_v[1]),
			float(max_v[2]) - float(min_v[2])))


func _expanded(aabb: AABB, margin: float) -> AABB:
	return AABB(aabb.position - Vector3.ONE * margin, aabb.size + Vector3.ONE * (margin * 2.0))


func _make_test_task() -> Resource:
	var task: Resource = _window.task_script.new()
	task.task_id = &"task_l1_std_door"
	task.display_name = "标准化测试门"
	task.category = &"door"
	task.purpose = "L1 标准化窗口集成测试用门体"
	task.producer = &"human"
	task.size_min = Vector3(0.8, 2.0, 0.2)
	task.size_max = Vector3(2.0, 3.0, 0.6)
	task.target_size = Vector3(1.2, 2.4, 0.3)
	task.tri_budget = 500
	task.lod1_budget = 250
	task.lod2_budget = 100
	task.texture_size = 512
	task.material_budget = 3
	task.uv_policy = &"world_scale"
	task.collision_policy = &"convex"
	task.origin_convention = "root_center"
	task.outward_axis = Vector3(0.0, 0.0, 1.0)
	task.up_axis = Vector3(0.0, 1.0, 0.0)
	task.root_embed = 0.12
	task.interface_requirements = "测试接口：两枚铰链"
	task.variant_count = 1
	task.status = &"draft"
	return task


func _make_crate_task() -> Resource:
	var task: Resource = _window.task_script.new()
	task.task_id = &"task_l1_std_crate"
	task.display_name = "标准化板条箱"
	task.category = &"decoration"
	task.purpose = "L1 正式 fixtures 完整流程用箱型资产"
	task.producer = &"human"
	task.size_min = Vector3(0.2, 0.2, 0.1)
	task.size_max = Vector3(2.0, 3.0, 1.0)
	task.target_size = Vector3(0.6, 0.6, 0.6)
	task.tri_budget = 500
	task.lod1_budget = 250
	task.lod2_budget = 100
	task.texture_size = 512
	task.material_budget = 3
	task.uv_policy = &"world_scale"
	task.collision_policy = &"convex"
	task.origin_convention = "root_center"
	task.outward_axis = Vector3(0.0, 0.0, 1.0)
	task.up_axis = Vector3(0.0, 1.0, 0.0)
	task.root_embed = 0.12
	task.interface_requirements = "无接口，占位测试"
	task.variant_count = 1
	task.status = &"draft"
	return task


func _task_index(task_id: String) -> int:
	for index in _window.tasks.size():
		if String(_window.tasks[index].task_id) == task_id:
			return index
	return -1


# ---------------------------------------------------------------------------
# 检查项

func _check_editor_entry_points() -> void:
	var plugin_script: GDScript = load(PLUGIN_SCRIPT_PATH)
	_record(plugin_script != null and plugin_script.can_instantiate(),
		"editor_plugin.gd compiles with standardization integration", PLUGIN_SCRIPT_PATH)
	if plugin_script != null:
		var has_entry := false
		for method in plugin_script.get_script_method_list():
			if String(method.get("name", "")) == "open_asset_standardization":
				has_entry = true
				break
		_record(has_entry, "editor_plugin.gd exposes open_asset_standardization()")
	var dock_script: GDScript = load(DOCK_SCRIPT_PATH)
	_record(dock_script != null and dock_script.get_source_code().contains("资产标准化"),
		"dock.gd adds 资产标准化 button", DOCK_SCRIPT_PATH)


func _check_window_opens_and_task_selection() -> void:
	if _window == null:
		_record(false, "window opens: script missing")
		return
	_window.open_standardization(TASK_DIR)
	if not _window.resolved:
		_record(false, "shared API resolved (PCGAssetTaskStore/PCGAtomicStore/PCGSurfaceHostData)")
		return
	_record(_window.store != null, "shared PCGAssetTaskStore instance created")
	_record(_window.inspector_script != null and _window.host_data_script != null
		and _window.asset_script != null and _window.asset_store_script != null,
		"PCGAssetMeshInspector / PCGSurfaceHostData / PCGStandardAsset(Store) scripts resolved")
	_record(_window.title == "L1 资产标准化与验收", "window title is L1 title", _window.title)
	_record(_window.task_option != null and _window.source_edit != null
		and _window.load_button != null and _window.calibrate_button != null
		and _window.host_option != null and _window.fit_button != null
		and _window.whitebox_button != null and _window.collision_button != null
		and _window.lod_button != null and _window.report_list != null
		and _window.publish_button != null and _window.reload_button != null,
		"task/source/calibrate/fit/whitebox/collision/lod/report/publish/reload controls exist")
	_record(_window.host_option.item_count == 3, "fit host option lists plane/cylinder/dome")
	_record(_window.visible, "window popup visible after open_standardization")
	var task := _make_test_task()
	var saved: Dictionary = _window.store.save_task(task, TASK_DIR)
	_record(saved.get("ok", false), "test task saved to temp directory", ", ".join(saved.get("errors", [])))
	_window.refresh_task_list()
	_record(_window.task_option.item_count == 1, "task selector lists saved L0 task")
	_window.select_task(0)
	_record(_window.current_task != null and String(_window.current_task.task_id) == "task_l1_std_door",
		"task selection loads L0 task")
	_record((_window.get_target_size() - Vector3(1.2, 2.4, 0.3)).length() < 0.001,
		"task selection applies target size to calibration form")
	_record(is_equal_approx(_window.root_embed_spin.value, 0.12), "task selection applies root_embed")
	if _capture_mode:
		_window.size = Vector2i(1120, 890)
		await process_frame
	await _capture("01_window_open")


## 620×640 小窗布局：加载按钮在可视区域、ScrollContainer 可滚动。
func _check_scroll_layout_at_small_size() -> void:
	if _window == null:
		_record(false, "scroll layout check skipped (window missing)")
		return
	var scrolls: Array = _window.find_children("*", "ScrollContainer", false, false)
	_record(not scrolls.is_empty(), "root content lives in a full-window ScrollContainer")
	if scrolls.is_empty():
		return
	var scroll: ScrollContainer = scrolls[0]
	_record(_window.load_button.text == "加载资源", "standalone load button is labeled 加载资源")
	_record(_window.task_option.clip_text, "task OptionButton clips long text")
	_record(_window.load_button.get_parent() == scroll.get_child(0),
		"load button placed at root level beside source row")
	var original_min := _window.min_size
	_window.min_size = Vector2i(620, 640)
	_window.size = Vector2i(620, 640)
	await process_frame
	await process_frame
	_record(_window.size == Vector2i(620, 640), "window shrinks to 620x640", str(_window.size))
	var visible_rect: Rect2 = scroll.get_global_rect()
	_record(_window.load_button.is_visible_in_tree(), "load button visible at 620x640")
	_record(visible_rect.intersects(_window.load_button.get_global_rect()),
		"load button inside visible area at 620x640",
		"button=%s visible=%s" % [str(_window.load_button.get_global_rect()), str(visible_rect)])
	var vbar := scroll.get_v_scroll_bar()
	_record(vbar.max_value > vbar.page, "ScrollContainer is scrollable at 620x640",
		"max=%f page=%f" % [vbar.max_value, vbar.page])
	scroll.scroll_vertical = 120
	await process_frame
	_record(scroll.scroll_vertical > 0, "ScrollContainer vertical scrolling works")
	scroll.scroll_vertical = 0
	await process_frame
	_window.min_size = original_min


func _check_problem_meshes_blocked() -> void:
	if _window == null or not _window.resolved:
		_record(false, "problem mesh checks skipped (window missing shared API)")
		return
	_window.set_source_mesh(_open_quad_mesh())
	var ids := _blocking_ids()
	_record(ids.has("closed") and ids.has("uv0") and ids.has("root"),
		"open floating quad blocked (closed/uv0/root)", ", ".join(ids))
	_record(_window.publish_button.disabled, "publish disabled for problem mesh")
	_record(_window.report_list.item_count > 0, "acceptance report rendered in list")
	_window.set_source_mesh(_nonmanifold_mesh())
	ids = _blocking_ids()
	_record(ids.has("zero_area_triangle") and ids.has("nonmanifold"),
		"degenerate non-manifold mesh blocked (zero_area/nonmanifold)", ", ".join(ids))
	_window.set_source_mesh(_box_mesh(Vector3(1.2, 2.4, 0.3), -0.3, false, true))
	ids = _blocking_ids()
	_record(ids.has("winding"), "inverted closed box blocked (winding/volume sign)", ", ".join(ids))
	_record(not ids.has("uv0"), "inverted box still passes uv0 (uv present)")
	await _capture("01b_problem_report")
	var refused: Dictionary = _window.publish()
	_record(not refused.get("ok", false), "publish refused while hard checks fail")


func _check_load_from_path() -> void:
	if _window == null or not _window.resolved:
		_record(false, "load-from-path checks skipped")
		return
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(TEMP_DIR))
	var mesh_path := TEMP_DIR + "/candidate_box.tres"
	_record(ResourceSaver.save(_box_mesh(Vector3(1.2, 2.4, 0.3), -0.3), mesh_path) == OK,
		"mesh resource saved for path loading", mesh_path)
	# 通过“加载资源”按钮的真实 pressed 信号驱动，而非只直接调用函数。
	_window.source_edit.text = mesh_path
	_window.load_button.pressed.emit()
	_record(_window.source_mesh != null and _window.status_label.text.begins_with("Mesh 已载入"),
		"Mesh resource loads via 加载资源 button", _window.status_label.text)
	var scene := PackedScene.new()
	var holder := MeshInstance3D.new()
	holder.mesh = _box_mesh(Vector3(1.2, 2.4, 0.3), -0.3)
	var wrapper := Node3D.new()
	wrapper.add_child(holder)
	owner_set(holder, wrapper)
	_record(scene.pack(wrapper) == OK, "packed scene built for path loading")
	var scene_path := TEMP_DIR + "/candidate_scene.tscn"
	_record(ResourceSaver.save(scene, scene_path) == OK, "packed scene saved", scene_path)
	_window.source_edit.text = scene_path
	_window.load_button.pressed.emit()
	_record(_window.source_mesh != null
		and _window.status_label.text.begins_with("PackedScene 网格已载入"),
		"PackedScene mesh loads via 加载资源 button", _window.status_label.text)
	_window.source_edit.text = "res://does/not/exist.tres"
	_window.load_button.pressed.emit()
	_record(_window.status_label.text.begins_with("加载失败"),
		"missing resource path reports failure via button", _window.status_label.text)


func owner_set(node: Node, owner: Node) -> void:
	node.owner = owner
	for child in node.get_children():
		owner_set(child, owner)


## 正式 assets/raw/valid_crate.tres 原始资源的完整流程：
## 真实加载按钮 → 校准 → 三主体试装 → 白盒/碰撞/LOD → 发布与重载，
## 明确断言有向体积为负（Godot 顺时针朝外约定）且无硬性失败。
func _check_valid_crate_full_flow() -> void:
	if _window == null or not _window.resolved:
		_record(false, "valid crate flow skipped (window missing shared API)")
		return
	var crate_path := "res://assets/raw/valid_crate.tres"
	_record(FileAccess.file_exists(crate_path),
		"exported fixture exists (run export_mesh_fixtures.gd)", crate_path)
	_record(ResourceLoader.exists(crate_path), "valid_crate.tres is loadable", crate_path)
	var saved: Dictionary = _window.store.save_task(_make_crate_task(), TASK_DIR)
	_record(saved.get("ok", false), "crate task saved", ", ".join(saved.get("errors", [])))
	_window.refresh_task_list()
	var crate_index := _task_index("task_l1_std_crate")
	_record(crate_index >= 0, "crate task listed after refresh")
	if crate_index < 0:
		return
	_window.select_task(crate_index)
	_record((_window.get_target_size() - Vector3(0.6, 0.6, 0.6)).length() < 0.001,
		"crate task applies target size to form")
	# 真实“加载资源”按钮驱动加载正式原始资源。
	_window.source_edit.text = crate_path
	_window.load_button.pressed.emit()
	_record(_window.source_mesh != null and _window.status_label.text.begins_with("Mesh 已载入"),
		"valid_crate loads via 加载资源 button", _window.status_label.text)
	# 顺时针朝外约定：单位箱体所有面一致时有向体积必须为 -1。
	var source_volume: float = _window._signed_volume(_window.source_mesh)
	_record(is_equal_approx(source_volume, -1.0),
		"valid_crate signed volume is consistently CW outward", "volume=%f" % source_volume)
	# 校准。
	var calibration: Dictionary = _window.calibrate()
	_record(calibration.get("ok", false), "crate calibrates", String(calibration.get("error", "")))
	var aabb: AABB = _window.active_analysis()["stats"]["aabb"]
	_record((aabb.size - Vector3(0.6, 0.6, 0.6)).length() < 0.01,
		"crate calibrated size matches target", str(aabb.size))
	_record(is_equal_approx(_window._signed_volume(_window.calibrated_mesh), -0.216),
		"crate calibrated volume stays consistently CW outward", "volume=%f" % _window._signed_volume(_window.calibrated_mesh))
	# 无硬性失败：验收报告里所有 blocking 条目必须通过。
	var ids := _blocking_ids()
	_record(ids.is_empty(), "crate acceptance has no blocking failures", ", ".join(ids))
	# 三主体试装（失败时报告具体字段）。
	var names := ["plane", "cylinder", "dome_cylinder"]
	for kind in 3:
		var fit: Dictionary = _window.trial_fit(kind)
		_record(fit.get("ok", false), "crate %s 试装 passes" % names[kind],
			"floating=%s pierces_back=%s reversed=%s embed=%.3f thickness=%.3f protrusion=%.3f"
			% [fit.get("floating", "?"), fit.get("pierces_back", "?"), fit.get("reversed", "?"),
				float(fit.get("embed_depth", 0.0)), float(fit.get("thickness", 0.0)),
				float(fit.get("protrusion", 0.0))])
	# 白盒 / 碰撞 / LOD。
	var whitebox: Dictionary = _window.generate_whitebox()
	_record(whitebox.get("ok", false), "crate whitebox generated")
	var collision: Dictionary = _window.generate_collision()
	_record(collision.get("ok", false) and String(collision.get("policy", "")) == "convex"
		and _window.collision_entries[0]["shape"] is ConvexPolygonShape3D
		and (_window.collision_entries[0]["shape"] as ConvexPolygonShape3D).points.size() == 8,
		"crate convex collision from 8 welded vertices")
	var lod: Dictionary = _window.generate_lod_status()
	_record(lod.get("ok", false) and _window.lod_entries.size() == 3
		and bool(_window.lod_entries[0]["passed"]) and bool(_window.lod_entries[1]["passed"]),
		"crate LOD status passes task budgets")
	_record(_blocking_ids().is_empty(), "crate still clean before publish", ", ".join(_blocking_ids()))
	await _capture("02c_valid_crate")
	# 发布与重载（同一临时发布目录；稳定 ID 每次新生成，不会撞重复发布）。
	_window.publish_dir_edit.text = PUBLISH_DIR
	var published: Dictionary = _window.publish()
	_record(published.get("ok", false), "crate publishes", String(published.get("error", "")))
	var reloaded: Dictionary = _window.reload_published()
	_record(reloaded.get("ok", false), "crate reload verifies",
		"; ".join(reloaded.get("mismatches", [])))
	var asset: Resource = reloaded.get("asset", null)
	_record(asset != null and asset.normalized_mesh != null
		and (asset.resolved_dimensions() - Vector3(0.6, 0.6, 0.6)).length() < 0.01,
		"crate reload restores normalized mesh and dimensions")
	_record(not (_window._extract_occupancy(asset) if asset != null else {}).is_empty(),
		"crate reload carries occupancy")
	# 恢复门任务与既有流程的前置状态。
	var door_index := _task_index("task_l1_std_door")
	if door_index >= 0:
		_window.select_task(door_index)


func _check_calibration() -> void:
	if _window == null or not _window.resolved:
		_record(false, "calibration checks skipped")
		return
	_window.set_source_mesh(_box_mesh(Vector3(1.2, 2.4, 0.3), -0.3))
	_window.set_target_size(Vector3(1.0, 2.0, 0.25))
	var result: Dictionary = _window.calibrate()
	_record(result.get("ok", false), "calibrate succeeds", String(result.get("error", "")))
	_record(_window.calibrated_mesh != null, "calibrated mesh produced")
	_record(_window.calibration_label.text.begins_with("已校准"), "calibration status label updated")
	var aabb: AABB = _window.active_analysis()["stats"]["aabb"]
	_record((aabb.size - Vector3(1.0, 2.0, 0.25)).length() < 0.01,
		"calibrated size matches target", str(aabb.size))
	_record(absf(aabb.position.y - (-0.24)) < 0.01,
		"calibrated root embeds root_embed × height below origin", "min_y=%f" % aabb.position.y)
	_record(_window.get_target_size() == Vector3(1.0, 2.0, 0.25),
		"target size survived round trip through form")
	_record(_blocking_ids().is_empty(), "calibrated good box passes all hard checks")
	_record(not _window.publish_button.disabled, "publish enabled after calibration passes")
	await _capture("02_loaded_calibrated")


func _check_trial_fit_hosts() -> void:
	if _window == null or not _window.resolved:
		_record(false, "trial fit checks skipped")
		return
	var names := ["plane", "cylinder", "dome_cylinder"]
	for kind in 3:
		var fit: Dictionary = _window.trial_fit(kind)
		_record(fit.get("ok", false), "%s 试装 passes" % names[kind],
			String(fit.get("error", "")))
		_record(float(fit.get("embed_depth", 0.0)) < float(fit.get("thickness", 0.0)),
			"%s 试装 embed within thickness" % names[kind])
	_record(_window.last_fit.size() == 3, "all three host fit results recorded")
	var report_ids := PackedStringArray()
	for entry in _window.last_acceptance.get("entries", []):
		report_ids.append(String(entry["id"]))
	_record(report_ids.has("fit_plane") and report_ids.has("fit_cylinder")
		and report_ids.has("fit_dome_cylinder"), "fit results rendered into acceptance report")
	await _capture("03_trial_fit")


func _check_fit_negative_cases() -> void:
	if _window == null or not _window.resolved:
		_record(false, "negative fit checks skipped")
		return
	_window.set_source_mesh(_open_quad_mesh())
	var fit: Dictionary = _window.trial_fit(0)
	_record(not fit.get("ok", false) and (bool(fit.get("floating", false)) or bool(fit.get("reversed", false))),
		"zero-depth quad flagged on plane host (floating or reversed)")
	_window.set_source_mesh(_box_mesh(Vector3(1.0, 1.0, 1.2), -0.1))
	fit = _window.trial_fit(0)
	_record(not fit.get("ok", false) and bool(fit.get("pierces_back", false)),
		"deep box flagged piercing plane host back side")


func _check_whitebox_collision_lod() -> void:
	if _window == null or not _window.resolved:
		_record(false, "whitebox/collision/lod checks skipped")
		return
	_window.set_source_mesh(_box_mesh(Vector3(1.2, 2.4, 0.3), -0.3))
	_window.set_target_size(Vector3(1.0, 2.0, 0.25))
	_window.calibrate()
	var whitebox: Dictionary = _window.generate_whitebox()
	_record(whitebox.get("ok", false) and _window.whitebox_mesh != null,
		"whitebox generated from calibrated AABB")
	_record(_window.whitebox_mesh is ArrayMesh and _window.whitebox_mesh.get_surface_count() > 0,
		"whitebox is a persisted ArrayMesh (PCGSurfacePreview)")
	_record((_window.whitebox_report["size"] - Vector3(1.0, 2.0, 0.25)).length() < 0.01,
		"whitebox size equals calibrated size", str(_window.whitebox_report["size"]))
	var collision: Dictionary = _window.generate_collision()
	_record(collision.get("ok", false) and String(collision.get("policy", "")) == "convex",
		"collision uses task collision_policy (convex)")
	_record(_window.collision_entries.size() == 1
		and _window.collision_entries[0]["shape"] is ConvexPolygonShape3D
		and (_window.collision_entries[0]["shape"] as ConvexPolygonShape3D).points.size() == 8,
		"convex collision hull built from 8 box vertices")
	var lod: Dictionary = _window.generate_lod_status()
	_record(lod.get("ok", false) and _window.lod_entries.size() == 3,
		"LOD status generated for three levels (PCGMeshLod)")
	_record(_window.lod_entries[0]["target"] == 500 and bool(_window.lod_entries[0]["passed"]),
		"LOD0 budget comes from task and 12-face mesh passes")
	_record(int(_window.lod_entries[1]["target"]) == 250
		and int(_window.lod_entries[1]["faces_out"]) <= 250
		and bool(_window.lod_entries[1]["passed"])
		and not String(_window.lod_entries[1]["method"]).is_empty(),
		"LOD1 real decimation meets task budget", str(_window.lod_entries[1]))
	_record(int(_window.lod_entries[2]["target"]) == 100 and bool(_window.lod_entries[2]["passed"]),
		"LOD2 real decimation meets task budget", str(_window.lod_entries[2]))
	_record(_window.status_list.item_count >= 3, "whitebox/collision/LOD rendered in status list")


func _check_publish_and_reload() -> void:
	if _window == null or not _window.resolved:
		_record(false, "publish/reload checks skipped")
		return
	_window.trial_fit(0)
	_window.trial_fit(1)
	_window.trial_fit(2)
	_window.generate_whitebox()
	_window.generate_collision()
	_window.generate_lod_status()
	_window.clearance_spin.set_value_no_signal(0.08)
	_window.visual_margin_spin.set_value_no_signal(0.2)
	_window.publish_dir_edit.text = PUBLISH_DIR
	var published: Dictionary = _window.publish()
	_record(published.get("ok", false), "publish succeeds after hard checks pass",
		String(published.get("error", "")))
	var path := String(published.get("path", ""))
	_record(path.ends_with(".asset.json") and FileAccess.file_exists(path),
		"standard asset .asset.json written to publish directory", path)
	var asset_id := String(published.get("asset_id", ""))
	_record(not asset_id.is_empty(), "publish returns stable asset id", asset_id)
	# 每级网格 .res 真实落盘且可被 ResourceLoader 重载。
	var slot_meshes := {"lod0": "", "lod1": "", "lod2": "", "whitebox": ""}
	for slot in slot_meshes:
		var mesh_path := PUBLISH_DIR + "/%s.%s.mesh.res" % [asset_id, slot]
		_record(FileAccess.file_exists(mesh_path), "mesh file written for slot %s" % slot, mesh_path)
		var resource: Resource = ResourceLoader.load(mesh_path)
		_record(resource is ArrayMesh and (resource as ArrayMesh).get_surface_count() > 0,
			"mesh file reloads as usable ArrayMesh (%s)" % slot)
	var manifest: Dictionary = published.get("manifest", {})
	_record(manifest.get("lods", {}).keys().size() == 2,
		"publish manifest records lod1/lod2 generation detail")
	if _capture_mode:
		var scrolls: Array = _window.find_children("*", "ScrollContainer", false, false)
		if not scrolls.is_empty():
			var sc := scrolls[0] as ScrollContainer
			sc.scroll_vertical = int(sc.get_v_scroll_bar().max_value)
			await process_frame
	await _capture("04_published")
	var json := JSON.new()
	_record(json.parse(FileAccess.get_file_as_string(path)) == OK and json.data is Dictionary,
		"published .asset.json is valid JSON")
	if json.data is Dictionary:
		var document := json.data as Dictionary
		_record(int(document.get("format_version", 0)) == 1 and document.get("payload") is Dictionary,
			"asset document carries format_version envelope with payload")
		var payload := document["payload"] as Dictionary
		_record(String(payload.get("task_id", "")) == "task_l1_std_door"
			and String(payload.get("display_name", "")) == "标准化测试门",
			"payload records task reference and display name")
		_record((payload.get("acceptance_report", {}) as Dictionary).get("verdict", "") in ["accepted", "accepted_with_notes"],
			"payload embeds acceptance report verdict")
		_record((payload.get("mesh_files", {}) as Dictionary).keys().size() == 4,
			"payload records all four mesh file slots")
	var reloaded: Dictionary = _window.reload_published()
	_record(reloaded.get("ok", false), "reload_published verifies via load_asset",
		"; ".join(reloaded.get("mismatches", [])))
	var asset: Resource = reloaded.get("asset", null)
	_record(asset != null and asset.normalized_mesh != null
		and asset.lod1_mesh != null and asset.lod2_mesh != null and asset.whitebox_mesh != null,
		"reload restores normalized/lod1/lod2/whitebox meshes")
	# occupancy 五类 AABB：保存重载后非空，净空/视觉扩展正确。
	var occupancy: Dictionary = {}
	var occ_prop: Variant = asset.get("occupancy") if asset != null else null
	if occ_prop is Dictionary and not (occ_prop as Dictionary).is_empty():
		occupancy = occ_prop
	elif asset != null and asset.acceptance_report.get("occupancy") is Dictionary:
		occupancy = asset.acceptance_report["occupancy"]
	_record(not occupancy.is_empty(), "reloaded asset carries non-empty occupancy")
	var occ_slots := PackedStringArray()
	for slot in ["solid", "embed", "exclusion", "clearance", "visual"]:
		if not (occupancy.get(slot) is Dictionary):
			occ_slots.append(slot)
	_record(occ_slots.is_empty(), "occupancy has all five category AABBs", ", ".join(occ_slots))
	if occupancy.has("solid"):
		var solid := _dict_to_aabb(occupancy["solid"])
		var mesh_aabb: AABB = asset.normalized_mesh.get_aabb()
		_record((solid.position - mesh_aabb.position).length() < 0.01
			and (solid.size - mesh_aabb.size).length() < 0.01,
			"occupancy.solid equals normalized mesh AABB")
		var expected_clearance := _expanded(solid, 0.08)
		_record((_dict_to_aabb(occupancy["clearance"]).position - expected_clearance.position).length() < 0.01
			and (_dict_to_aabb(occupancy["clearance"]).size - expected_clearance.size).length() < 0.01,
			"occupancy.clearance expands solid by edited 净空余量 0.08")
		var expected_visual := _expanded(solid, 0.2)
		_record((_dict_to_aabb(occupancy["visual"]).position - expected_visual.position).length() < 0.01
			and (_dict_to_aabb(occupancy["visual"]).size - expected_visual.size).length() < 0.01,
			"occupancy.visual expands solid by edited 视觉保护区扩展 0.2")
		# 与核心 derive_occupancy（余量取表单编辑值 0.08/0.2）逐区一致：
		# 发布写入与重载核对走同一推导源。
		var expected_occ: Dictionary = asset.derive_occupancy(0.08, 0.2)
		var mismatched_slots := PackedStringArray()
		for slot in ["solid", "embed", "exclusion", "clearance", "visual"]:
			var expected_zone := _dict_to_aabb(expected_occ[slot])
			var actual_zone := _dict_to_aabb(occupancy[slot])
			if (actual_zone.position - expected_zone.position).length() > 0.01 \
				or (actual_zone.size - expected_zone.size).length() > 0.01:
				mismatched_slots.append(slot)
		_record(mismatched_slots.is_empty(),
			"occupancy matches core derive_occupancy with edited margins", ", ".join(mismatched_slots))
		var embed := _dict_to_aabb(occupancy["embed"])
		_record(embed.size.z > 0.0,
			"occupancy.embed covers below-surface root portion", "depth=%f" % embed.size.z)
		var expected_exclusion := _expanded(embed, 0.05)
		_record((_dict_to_aabb(occupancy["exclusion"]).position - expected_exclusion.position).length() < 0.01
			and (_dict_to_aabb(occupancy["exclusion"]).size - expected_exclusion.size).length() < 0.01,
			"occupancy.exclusion expands embed by 0.05")
	await _capture("05_reloaded")
	if asset != null:
		_record((asset.resolved_dimensions() - Vector3(1.0, 2.0, 0.25)).length() < 0.01,
			"reloaded asset dimensions match calibrated mesh", str(asset.resolved_dimensions()))
	# 篡改清单中的尺寸，重载必须发现不一致。
	var tampered: Dictionary = json.data as Dictionary
	(tampered["payload"] as Dictionary)["dimensions"] = [9.9, 9.9, 9.9]
	var file := FileAccess.open(path, FileAccess.WRITE)
	file.store_string(JSON.stringify(tampered, "\t"))
	file.close()
	reloaded = _window.reload_published()
	_record(not reloaded.get("ok", false) and not reloaded.get("mismatches", []).is_empty(),
		"reload detects tampered manifest", "; ".join(reloaded.get("mismatches", [])))


func _check_publish_requires_task() -> void:
	var second: Window = await _make_window()
	if second == null:
		_record(false, "second window instance created")
		return
	second.open_standardization(TASK_DIR)
	second.set_source_mesh(_box_mesh(Vector3(1.2, 2.4, 0.3), -0.3))
	var refused: Dictionary = second.publish()
	_record(not refused.get("ok", false), "publish refused without selected L0 task")
	second.hide()
	second.queue_free()


func _cleanup() -> void:
	var base := DirAccess.open(TEMP_DIR)
	if base != null:
		for file_name in base.get_files():
			base.remove(file_name)
		for dir_name in ["tasks", "published"]:
			var sub := DirAccess.open(TEMP_DIR + "/" + dir_name)
			if sub != null:
				for file_name in sub.get_files():
					sub.remove(file_name)
				base.remove(dir_name)
	var user := DirAccess.open("user://")
	if user != null:
		user.remove("pcg_l1_standardization_test")
	if _window != null and is_instance_valid(_window):
		_window.queue_free()
