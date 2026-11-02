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

var checks_run := 0
var failures: Array[String] = []
var _window: Window


func _initialize() -> void:
	_main()


func _main() -> void:
	print("L1_STD_BEGIN: asset standardization window UI/integration checks")
	_check_editor_entry_points()
	_cleanup()
	_window = await _make_window()
	await _check_window_opens_and_task_selection()
	await _check_problem_meshes_blocked()
	await _check_load_from_path()
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
	var result: Dictionary = _window.load_source_from_path(mesh_path)
	_record(result.get("ok", false) and String(result.get("kind", "")) == "mesh",
		"Mesh resource loads from path", String(result.get("error", "")))
	var scene := PackedScene.new()
	var holder := MeshInstance3D.new()
	holder.mesh = _box_mesh(Vector3(1.2, 2.4, 0.3), -0.3)
	var wrapper := Node3D.new()
	wrapper.add_child(holder)
	owner_set(holder, wrapper)
	_record(scene.pack(wrapper) == OK, "packed scene built for path loading")
	var scene_path := TEMP_DIR + "/candidate_scene.tscn"
	_record(ResourceSaver.save(scene, scene_path) == OK, "packed scene saved", scene_path)
	result = _window.load_source_from_path(scene_path)
	_record(result.get("ok", false) and String(result.get("kind", "")) == "packed_scene",
		"PackedScene mesh loads from path", String(result.get("error", "")))
	result = _window.load_source_from_path("res://does/not/exist.tres")
	_record(not result.get("ok", false), "missing resource path reports failure")


func owner_set(node: Node, owner: Node) -> void:
	node.owner = owner
	for child in node.get_children():
		owner_set(child, owner)


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
