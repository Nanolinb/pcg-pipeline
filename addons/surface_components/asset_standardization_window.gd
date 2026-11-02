@tool
extends Window

# v0.16 L1 可见资产标准化工作台：把候选 Mesh / PackedScene 转成可在任何
# 兼容主体上稳定使用的标准组件。基于共享 v0.16 核心模块，全部通过全局类
# 运行时解析，缺失共享 API 时明确报告而不是静默降级：
# - PCGAssetTask / PCGAssetTaskStore：L0 任务与预算来源；
# - PCGAssetMeshInspector：几何体检（零面积/非流形/开放/NaN/预算）与真实
#   校准（basis + root_offset + 顶点焊接 + 退化清理）；
# - PCGSurfaceHostData：平面 / 圆柱 / 半球圆柱试装；
# - PCGSurfacePreview / PCGMeshLod / PCGStableId / PCGStandardAssetStore：
#   白盒、真实 LOD 状态、稳定 ID 与正式资产发布（assets/published，
#   JSON 信封 + 每级网格 .res），不保留第二套 JSON-only 发布格式。
#
# 流程：选择 L0 任务 → 载入候选网格 → 验收报告 → 校准 → 三主体试装 →
# 白盒/碰撞/LOD 状态 → 硬性检查全部通过且已校准 → publish → load_asset 重载。
# 所有控件行为可被 headless 测试驱动（set_source_mesh 注入、发布目录可指向
# user:// 临时目录）。

signal asset_published(publish_path: String)

const TASK_STORE_CLASS_NAME := "PCGAssetTaskStore"
const TASK_CLASS_NAME := "PCGAssetTask"
const INSPECTOR_CLASS_NAME := "PCGAssetMeshInspector"
const HOST_DATA_CLASS_NAME := "PCGSurfaceHostData"
const PREVIEW_CLASS_NAME := "PCGSurfacePreview"
const LOD_CLASS_NAME := "PCGMeshLod"
const STABLE_ID_CLASS_NAME := "PCGStableId"
const ASSET_CLASS_NAME := "PCGStandardAsset"
const ASSET_STORE_CLASS_NAME := "PCGStandardAssetStore"
const SHARED_DIR_CANDIDATES := [
	"res://addons/pcg_shared",
]
const DEFAULT_TASKS_DIRECTORY := "res://assets/tasks"
const DEFAULT_PUBLISH_DIRECTORY := "res://assets/published"
const EPS := 0.0001
## docs/component_authoring.md：Godot 顺时针正面绕序、朝外约定 → 封闭网格有向体积为负。
const VOLUME_TOLERANCE := 0.01
const CHECKED_BY := "L1 资产标准化与验收窗口"
## 与 PCGStandardAsset.OCCUPANCY_MARGIN 一致：禁入区 = 嵌入区外扩该余量。
const EXCLUSION_MARGIN := 0.05

var tasks_directory := DEFAULT_TASKS_DIRECTORY
var publish_directory := DEFAULT_PUBLISH_DIRECTORY
var store_script: GDScript
var task_script: GDScript
var inspector_script: GDScript
var host_data_script: GDScript
var preview_script: GDScript
var lod_script: GDScript
var stable_id_script: GDScript
var asset_script: GDScript
var asset_store_script: GDScript
var store: RefCounted
var standard_store: RefCounted
var tasks: Array = []
var current_task: Resource
var resolved := false

var source_mesh: Mesh
var source_path := ""
var calibrated_mesh: ArrayMesh
var calibration: Dictionary = {}
var whitebox_mesh: ArrayMesh
var whitebox_report: Dictionary = {}
var collision_entries: Array = []
var lod_entries: Array = []
var last_fit: Dictionary = {}
var last_acceptance: Dictionary = {}
var last_publish: Dictionary = {}
var last_occupancy: Dictionary = {}
var reloaded_asset: Resource

var task_option: OptionButton
var refresh_task_button: Button
var source_edit: LineEdit
var load_button: Button
var mesh_info_label: Label
var target_size_box: HBoxContainer
var root_embed_spin: SpinBox
var clearance_spin: SpinBox
var visual_margin_spin: SpinBox
var outward_box: HBoxContainer
var up_box: HBoxContainer
var calibrate_button: Button
var calibration_label: Label
var host_option: OptionButton
var fit_button: Button
var fit_label: Label
var whitebox_button: Button
var collision_button: Button
var lod_button: Button
var status_list: ItemList
var report_list: ItemList
var publish_dir_edit: LineEdit
var publish_button: Button
var reload_button: Button
var status_label: Label


func _ready() -> void:
	title = "L1 资产标准化与验收"
	close_requested.connect(hide)
	min_size = Vector2i(680, 760)
	_build_ui()
	_resolve_shared_scripts()


func open_standardization(directory: String = "") -> void:
	if not directory.is_empty():
		tasks_directory = directory
	if store != null:
		store.directory = tasks_directory
	if not resolved:
		_resolve_shared_scripts()
	if not resolved:
		if status_label != null:
			status_label.text = "共享 L1 API 缺失：未找到 PCGAssetTaskStore / PCGAssetMeshInspector / PCGStandardAssetStore 等"
		return
	refresh_task_list()
	popup_centered(Vector2i(700, 820))


func refresh_task_list() -> void:
	if store == null:
		return
	tasks = store.list_tasks(tasks_directory)
	task_option.clear()
	for task in tasks:
		task_option.add_item("%s  %s" % [String(task.task_id), String(task.display_name)])
	_select_current_in_option()


func select_task(index: int) -> void:
	_on_task_selected(index)


func set_source_mesh(mesh: Mesh, path: String = "") -> Dictionary:
	source_mesh = mesh
	source_path = path
	calibrated_mesh = null
	calibration = {}
	whitebox_mesh = null
	whitebox_report = {}
	collision_entries = []
	lod_entries = []
	last_fit = {}
	reloaded_asset = null
	last_occupancy = {}
	if source_edit != null and not path.is_empty():
		source_edit.text = path
	_update_mesh_info()
	_update_calibration_label()
	_update_fit_label()
	_update_status_list()
	run_acceptance()
	_set_status("已注入网格" if path.is_empty() else "已载入 %s" % path)
	return {"ok": true}


func load_source_from_path(path: String) -> Dictionary:
	var trimmed := path.strip_edges()
	if trimmed.is_empty():
		_set_status("加载失败：路径为空")
		return {"ok": false, "error": "empty path"}
	if not ResourceLoader.exists(trimmed):
		_set_status("加载失败：资源不存在: %s" % trimmed)
		return {"ok": false, "error": "resource not found: %s" % trimmed}
	var resource: Resource = load(trimmed)
	if resource == null:
		_set_status("加载失败：资源载入失败: %s" % trimmed)
		return {"ok": false, "error": "load failed: %s" % trimmed}
	if resource is Mesh:
		set_source_mesh(resource, trimmed)
		_set_status("Mesh 已载入: %s" % trimmed)
		return {"ok": true, "kind": "mesh"}
	if resource is PackedScene:
		var instance := (resource as PackedScene).instantiate()
		var found: Mesh
		if instance is MeshInstance3D and (instance as MeshInstance3D).mesh != null:
			found = (instance as MeshInstance3D).mesh
		else:
			for child in instance.find_children("*", "MeshInstance3D", true, false):
				if (child as MeshInstance3D).mesh != null:
					found = (child as MeshInstance3D).mesh
					break
		if found == null:
			instance.queue_free()
			_set_status("加载失败：PackedScene 中未找到 MeshInstance3D 网格: %s" % trimmed)
			return {"ok": false, "error": "no MeshInstance3D mesh in %s" % trimmed}
		set_source_mesh(found, trimmed)
		_set_status("PackedScene 网格已载入: %s" % trimmed)
		return {"ok": true, "kind": "packed_scene"}
	_set_status("加载失败：资源类型不支持（需要 Mesh 或 PackedScene）: %s" % trimmed)
	return {"ok": false, "error": "unsupported resource type: %s" % trimmed}


func set_target_size(value: Vector3) -> void:
	_set_vec3_spins(target_size_box, value)


func get_target_size() -> Vector3:
	return _vec3_spins(target_size_box)


func active_mesh() -> Mesh:
	return calibrated_mesh if calibrated_mesh != null else source_mesh


func active_analysis() -> Dictionary:
	var mesh := active_mesh()
	if mesh == null:
		return {}
	return _inspect(mesh)


func run_acceptance() -> Dictionary:
	last_acceptance = _build_acceptance()
	_refresh_report_view()
	return last_acceptance


func calibrate() -> Dictionary:
	if source_mesh == null:
		_set_status("校准失败：尚未载入源网格")
		return {"ok": false, "error": "no source mesh"}
	var target := get_target_size()
	if target.x <= EPS or target.y <= EPS or target.z <= EPS:
		_set_status("校准失败：目标尺寸必须为正")
		return {"ok": false, "error": "target size must be positive"}
	var outward := _vec3_spins(outward_box)
	if outward.length_squared() < EPS:
		_set_status("校准失败：外法线轴不能为零")
		return {"ok": false, "error": "outward axis is zero"}
	outward = outward.normalized()
	var up := _vec3_spins(up_box)
	if up.length_squared() < EPS:
		_set_status("校准失败：上方向轴不能为零")
		return {"ok": false, "error": "up axis is zero"}
	up = (up - outward * up.dot(outward)).normalized()
	if up.length_squared() < EPS:
		_set_status("校准失败：上方向轴与外法线轴平行")
		return {"ok": false, "error": "up axis parallel to outward axis"}
	if inspector_script == null:
		_set_status("校准失败：PCGAssetMeshInspector 未解析")
		return {"ok": false, "error": "inspector api missing"}
	# 旋转基（+Z=外法线，+Y=上方向）与统一缩放由 Inspector 内部按同一公式计算；
	# 这里先精确求变换后 AABB，再推导 root_center 原点偏移。
	var basis := Basis(up.cross(outward).normalized(), up, outward)
	var to_local := basis.inverse()
	var source_report := _inspect(source_mesh)
	var source_aabb: AABB = source_report["stats"]["aabb"]
	var scale := INF
	for axis in 3:
		if source_aabb.size[axis] > EPS:
			scale = minf(scale, target[axis] / source_aabb.size[axis])
	if scale == INF or scale <= EPS:
		_set_status("校准失败：源网格尺寸为零")
		return {"ok": false, "error": "source mesh has zero size"}
	var rotated_aabb := AABB()
	var first := true
	for surface_index in source_mesh.get_surface_count():
		var verts: PackedVector3Array = source_mesh.surface_get_arrays(surface_index)[Mesh.ARRAY_VERTEX]
		for vertex in verts:
			var point := to_local * (vertex * scale)
			if first:
				rotated_aabb = AABB(point, Vector3.ZERO)
				first = false
			else:
				rotated_aabb = rotated_aabb.expand(point)
	var root_embed := float(root_embed_spin.value)
	var origin := Vector3(
		(rotated_aabb.position.x + rotated_aabb.end.x) * 0.5,
		rotated_aabb.position.y + root_embed * rotated_aabb.size.y,
		(rotated_aabb.position.z + rotated_aabb.end.z) * 0.5)
	var inspector: RefCounted = inspector_script.new()
	var result: Dictionary = inspector.calibrate_mesh(source_mesh, target, -origin, to_local)
	if not result.get("ok", false):
		var details := PackedStringArray()
		for line in result.get("errors", []):
			details.append(String(line))
		_set_status("校准失败：%s" % "; ".join(details))
		return {"ok": false, "error": "; ".join(details)}
	calibrated_mesh = result["mesh"]
	calibration = {
		"ok": true,
		"scale": scale,
		"target_size": target,
		"root_embed": root_embed,
		"outward_axis": outward,
		"up_axis": up,
		"origin_convention": "root_center",
		"origin_offset": origin,
		"actions": result.get("actions", []),
	}
	whitebox_mesh = null
	whitebox_report = {}
	collision_entries = []
	lod_entries = []
	last_fit = {}
	last_occupancy = {}
	reloaded_asset = null
	_update_mesh_info()
	_update_calibration_label()
	run_acceptance()
	var actions := PackedStringArray()
	for action in result.get("actions", []):
		actions.append(String(action))
	_set_status("校准完成：缩放 %.4f（%s）" % [scale, ", ".join(actions)])
	return calibration


func trial_fit(host_kind: int) -> Dictionary:
	var mesh := active_mesh()
	if mesh == null:
		_set_status("试装失败：尚未载入网格")
		return {"ok": false, "error": "no mesh"}
	if host_data_script == null:
		_set_status("试装失败：PCGSurfaceHostData 未解析")
		return {"ok": false, "error": "host data api missing"}
	var aabb: AABB = _inspect(mesh)["stats"]["aabb"]
	var host: RefCounted = host_data_script.new()
	match host_kind:
		0:
			host.configure_plane(Vector3(6.0, 4.6, 0.36))
		1:
			host.configure_cylinder(1.35, 3.8, 0.7, false)
		2:
			host.configure_cylinder(1.35, 3.8, 0.7, true)
		_:
			_set_status("试装失败：未知主体类型 %d" % host_kind)
			return {"ok": false, "error": "unknown host kind %d" % host_kind}
	var component_size := Vector2(maxf(aabb.size.x, EPS), maxf(aabb.size.y, EPS))
	var anchor: Vector2 = host.clamp_anchor(Vector2.ZERO, component_size)
	var embed := -aabb.position.z
	var protrusion := aabb.end.z
	var gap := aabb.position.z
	var thickness := float(host.thickness)
	var host_names := [&"plane", &"cylinder", &"dome_cylinder"]
	var result := {
		"ok": true,
		"host_kind": int(host.surface_kind),
		"host_name": String(host_names[int(host.surface_kind)]),
		"anchor": [anchor.x, anchor.y],
		"embed_depth": embed,
		"thickness": thickness,
		"protrusion": protrusion,
		# 漂浮 = 网格与主体表面存在间隙；穿背 = 嵌入深度超过主体厚度；
		# 反转 = 网格不向外（+法线）突出。根部嵌入由校准沿 Y 轴保证。
		"floating": gap > EPS,
		"pierces_back": embed > thickness + EPS,
		"reversed": protrusion < EPS,
	}
	result["ok"] = not (result["floating"] or result["pierces_back"] or result["reversed"])
	last_fit[int(host.surface_kind)] = result
	run_acceptance()
	_update_fit_label()
	if result["ok"]:
		_set_status("试装 %s：通过（锚点 %.3f, %.3f）" % [result["host_name"], anchor.x, anchor.y])
	else:
		_set_status("试装 %s：未通过（漂浮=%s 穿背=%s 反转=%s）"
			% [result["host_name"], result["floating"], result["pierces_back"], result["reversed"]])
	return result


func generate_whitebox() -> Dictionary:
	var mesh := active_mesh()
	if mesh == null:
		_set_status("白盒失败：尚未载入网格")
		return {"ok": false, "error": "no mesh"}
	if preview_script == null:
		_set_status("白盒失败：PCGSurfacePreview 未解析")
		return {"ok": false, "error": "preview api missing"}
	var aabb: AABB = _inspect(mesh)["stats"]["aabb"]
	whitebox_mesh = preview_script.call("make_whitebox_mesh", aabb)
	whitebox_report = {
		"ok": true,
		"size": aabb.size,
		"center": aabb.get_center(),
		"tri_count": _face_count(whitebox_mesh),
	}
	_update_status_list()
	_set_status("白盒已生成：%.3f × %.3f × %.3f m" % [aabb.size.x, aabb.size.y, aabb.size.z])
	return whitebox_report


func generate_collision() -> Dictionary:
	var mesh := active_mesh()
	if mesh == null:
		_set_status("碰撞生成失败：尚未载入网格")
		return {"ok": false, "error": "no mesh"}
	var policy := String(_task_collision_policy())
	var aabb: AABB = _inspect(mesh)["stats"]["aabb"]
	collision_entries = []
	match policy:
		"none":
			collision_entries.append({"policy": "none", "description": "碰撞策略 none：不生成碰撞体"})
		"box":
			var box_shape := BoxShape3D.new()
			box_shape.size = aabb.size
			collision_entries.append({"policy": "box", "description": "盒碰撞体 %.3f×%.3f×%.3f m" % [aabb.size.x, aabb.size.y, aabb.size.z], "shape": box_shape})
		"convex":
			var convex_shape := ConvexPolygonShape3D.new()
			convex_shape.points = _unique_vertices(mesh)
			collision_entries.append({"policy": "convex", "description": "凸包碰撞体（%d 顶点）" % convex_shape.points.size(), "shape": convex_shape})
		"concave":
			var concave_shape := ConcavePolygonShape3D.new()
			concave_shape.set_faces(_triangle_positions(mesh))
			collision_entries.append({"policy": "concave", "description": "精确凹面碰撞体（%d 三角面）" % _face_count(mesh), "shape": concave_shape})
		_:
			_set_status("碰撞生成失败：未知碰撞策略 %s" % policy)
			return {"ok": false, "error": "unknown collision policy %s" % policy}
	_update_status_list()
	_set_status("碰撞已生成（策略 %s）" % policy)
	return {"ok": true, "policy": policy, "entries": collision_entries}


func generate_lod_status() -> Dictionary:
	var mesh := active_mesh()
	if mesh == null:
		_set_status("LOD 状态失败：尚未载入网格")
		return {"ok": false, "error": "no mesh"}
	if lod_script == null:
		_set_status("LOD 状态失败：PCGMeshLod 未解析")
		return {"ok": false, "error": "lod api missing"}
	var lod0_faces := _face_count(mesh)
	var budgets := [5000, 1250, 312]
	if current_task != null:
		budgets = [int(current_task.tri_budget), int(current_task.lod1_budget), int(current_task.lod2_budget)]
	lod_entries = [{
		"level": 0,
		"faces_in": lod0_faces,
		"faces_out": lod0_faces,
		"target": int(budgets[0]),
		"method": "source",
		"passed": int(budgets[0]) <= 0 or lod0_faces <= int(budgets[0]),
	}]
	var capability: Dictionary = lod_script.call("capability", mesh)
	for level in [1, 2]:
		var budget := int(budgets[level])
		var entry := {
			"level": level,
			"faces_in": lod0_faces,
			"faces_out": 0,
			"target": budget,
			"method": "unavailable",
			"passed": false,
			"verdict": "",
		}
		if not capability.get("ok", false):
			entry["verdict"] = "无法自动减面：%s（需显式 LOD%d）" % ["; ".join(capability.get("errors", [])), level]
		else:
			var target := budget
			if target <= 0:
				target = maxi(1, lod0_faces >> (level * 2))
			var decimated: Dictionary = lod_script.call("decimate", mesh, target)
			if decimated.get("ok", false):
				entry["faces_out"] = int(decimated["faces_out"])
				entry["method"] = String(decimated["method"])
				entry["passed"] = budget <= 0 or entry["faces_out"] <= budget
				entry["verdict"] = "%s %d→%d 面" % [entry["method"], lod0_faces, entry["faces_out"]]
				if not String(decimated.get("warning", "")).is_empty():
					entry["verdict"] += "（%s）" % decimated["warning"]
			else:
				entry["verdict"] = "减面失败：%s" % "; ".join(decimated.get("errors", []))
		lod_entries.append(entry)
	lod_entries[0]["verdict"] = "%d 面 / 预算 %d → %s" % [lod0_faces, int(budgets[0]),
		"通过" if lod_entries[0]["passed"] else "超预算"]
	_update_status_list()
	_set_status("LOD 状态已更新（LOD0 实际 %d 面）" % lod0_faces)
	return {"ok": true, "entries": lod_entries}


func publish() -> Dictionary:
	last_acceptance = _build_acceptance()
	_refresh_report_view()
	if active_mesh() == null:
		_set_status("发布被拒绝：尚未载入网格")
		return _publish_result(false, "no mesh")
	if current_task == null or String(current_task.task_id).is_empty():
		_set_status("发布被拒绝：请先选择 L0 任务单")
		return _publish_result(false, "no task selected")
	var blocking := _blocking_entries(last_acceptance)
	if not blocking.is_empty():
		_set_status("发布被拒绝：%d 项硬性检查未通过" % blocking.size())
		return _publish_result(false, "acceptance has %d blocking entries" % blocking.size())
	if calibrated_mesh == null:
		_set_status("发布被拒绝：请先执行校准（需要规范化网格作为 LOD0 真源）")
		return _publish_result(false, "not calibrated")
	if asset_store_script == null or asset_script == null or stable_id_script == null:
		_set_status("发布被拒绝：PCGStandardAssetStore / PCGStandardAsset / PCGStableId 未解析")
		return _publish_result(false, "standard asset api missing")
	if standard_store == null:
		standard_store = asset_store_script.new()
	var asset := _build_standard_asset()
	if asset == null:
		return _publish_result(false, "cannot build standard asset")
	var dir := publish_dir_edit.text.strip_edges()
	if dir.is_empty():
		dir = publish_directory
	var published: Dictionary = standard_store.publish(asset, dir)
	if not published.get("ok", false):
		var details := PackedStringArray()
		for line in published.get("errors", []):
			details.append(String(line))
		_set_status("发布失败：%s" % "; ".join(details))
		return _publish_result(false, "; ".join(details))
	_apply_publish_manifest(published.get("manifest", {}))
	last_publish = _publish_result(true, "")
	last_publish["path"] = String(published.get("path", ""))
	last_publish["asset_id"] = String(asset.asset_id())
	last_publish["manifest"] = published.get("manifest", {})
	reloaded_asset = asset
	_set_status("已发布: %s" % last_publish["path"])
	asset_published.emit(last_publish["path"])
	return last_publish


func reload_published() -> Dictionary:
	if asset_store_script == null:
		_set_status("重载失败：PCGStandardAssetStore 未解析")
		return {"ok": false, "error": "standard asset store missing", "mismatches": PackedStringArray()}
	var path := String(last_publish.get("path", ""))
	if path.is_empty() or not FileAccess.file_exists(path):
		_set_status("重载失败：找不到已发布资产清单")
		return {"ok": false, "error": "asset manifest not found", "mismatches": PackedStringArray()}
	if standard_store == null:
		standard_store = asset_store_script.new()
	var loaded: Dictionary = standard_store.load_asset(path)
	if not loaded.get("ok", false):
		var details := PackedStringArray()
		for line in loaded.get("errors", []):
			details.append(String(line))
		_set_status("重载失败：%s" % "; ".join(details))
		return {"ok": false, "error": "; ".join(details), "mismatches": PackedStringArray()}
	var asset: Resource = loaded["asset"]
	var mismatches := PackedStringArray()
	if current_task != null and String(asset.task_id) != String(current_task.task_id):
		mismatches.append("task_id %s != %s" % [String(asset.task_id), String(current_task.task_id)])
	var restored_mesh: ArrayMesh = asset.normalized_mesh
	var current_aabb: AABB = restored_mesh.get_aabb()
	if (asset.resolved_dimensions() - current_aabb.size).length() > 0.01:
		mismatches.append("dimensions %s 与网格 AABB 不一致" % str(asset.resolved_dimensions()))
	if not (asset.lod1_mesh != null and asset.lod1_mesh.get_surface_count() > 0
		and asset.lod2_mesh != null and asset.lod2_mesh.get_surface_count() > 0
		and asset.whitebox_mesh != null and asset.whitebox_mesh.get_surface_count() > 0):
		mismatches.append("重载资产缺少 lod1/lod2/whitebox 网格")
	# 占用五类 AABB：优先读核心正式字段，回退验收报告内镜像。
	last_occupancy = _extract_occupancy(asset)
	if last_occupancy.is_empty():
		mismatches.append("重载资产缺少 occupancy 五类 AABB")
	else:
		for problem in _verify_occupancy(last_occupancy, restored_mesh.get_aabb()):
			mismatches.append(problem)
	# 恢复窗口状态：网格、白盒、LOD 与报告都以重载资产为准重算。
	reloaded_asset = asset
	calibrated_mesh = restored_mesh
	calibration = {"ok": true, "scale": 1.0, "target_size": current_aabb.size,
		"root_embed": float(asset.root_embed), "outward_axis": asset.outward_axis,
		"up_axis": asset.up_axis, "origin_convention": "root_center",
		"origin_offset": Vector3.ZERO, "actions": ["reloaded_from_publish"]}
	whitebox_mesh = asset.whitebox_mesh
	whitebox_report = {"ok": true, "size": asset.whitebox_mesh.get_aabb().size,
		"center": asset.whitebox_mesh.get_aabb().get_center(),
		"tri_count": _face_count(asset.whitebox_mesh)}
	_restore_lod_entries(asset)
	_update_mesh_info()
	_update_calibration_label()
	_update_status_list()
	run_acceptance()
	var verdict := String(asset.acceptance_report.get("verdict", ""))
	var ok := mismatches.is_empty() and not verdict.is_empty()
	_set_status("重载核对%s：%s（验收 %s）" % ["通过" if ok else "发现差异", path, verdict])
	return {"ok": ok, "path": path, "asset": asset, "mismatches": mismatches}


# ---------------------------------------------------------------------------
# 内部实现

func _resolve_shared_scripts() -> void:
	if resolved and store != null and standard_store != null and inspector_script != null:
		return
	store_script = _find_shared_script(TASK_STORE_CLASS_NAME)
	task_script = _find_shared_script(TASK_CLASS_NAME)
	inspector_script = _find_shared_script(INSPECTOR_CLASS_NAME)
	host_data_script = _find_shared_script(HOST_DATA_CLASS_NAME)
	preview_script = _find_shared_script(PREVIEW_CLASS_NAME)
	lod_script = _find_shared_script(LOD_CLASS_NAME)
	stable_id_script = _find_shared_script(STABLE_ID_CLASS_NAME)
	asset_script = _find_shared_script(ASSET_CLASS_NAME)
	asset_store_script = _find_shared_script(ASSET_STORE_CLASS_NAME)
	resolved = store_script != null and inspector_script != null and host_data_script != null \
		and preview_script != null and lod_script != null and stable_id_script != null \
		and asset_script != null and asset_store_script != null
	if store_script != null and store == null:
		store = store_script.new()
		if store != null:
			store.directory = tasks_directory
	if asset_store_script != null and standard_store == null:
		standard_store = asset_store_script.new()


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


func _inspect(mesh: Mesh) -> Dictionary:
	var inspector: RefCounted = inspector_script.new()
	return inspector.inspect_mesh(mesh, current_task)


func _face_count(mesh: Mesh) -> int:
	if mesh == null:
		return 0
	var faces := 0
	for surface_index in mesh.get_surface_count():
		var arrays: Array = mesh.surface_get_arrays(surface_index)
		var indices: PackedInt32Array = arrays[Mesh.ARRAY_INDEX] if arrays[Mesh.ARRAY_INDEX] != null else PackedInt32Array()
		if indices.is_empty():
			faces += arrays[Mesh.ARRAY_VERTEX].size() / 3
		else:
			faces += indices.size() / 3
	return faces


func _unique_vertices(mesh: Mesh) -> PackedVector3Array:
	var seen := {}
	var points := PackedVector3Array()
	for surface_index in mesh.get_surface_count():
		for vertex in mesh.surface_get_arrays(surface_index)[Mesh.ARRAY_VERTEX]:
			var key := "%0.6f,%0.6f,%0.6f" % [vertex.x, vertex.y, vertex.z]
			if seen.has(key):
				continue
			seen[key] = true
			points.append(vertex)
	return points


func _triangle_positions(mesh: Mesh) -> PackedVector3Array:
	var faces := PackedVector3Array()
	for surface_index in mesh.get_surface_count():
		var arrays: Array = mesh.surface_get_arrays(surface_index)
		var verts: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
		var indices: PackedInt32Array = arrays[Mesh.ARRAY_INDEX] if arrays[Mesh.ARRAY_INDEX] != null else PackedInt32Array()
		if indices.is_empty():
			for vertex in verts:
				faces.append(vertex)
		else:
			for index in indices:
				faces.append(verts[index])
	return faces


func _signed_volume(mesh: Mesh) -> float:
	# 仅索引网格参与判定（非索引条带无法可靠计算有向体积）。
	var volume := 0.0
	for surface_index in mesh.get_surface_count():
		var arrays: Array = mesh.surface_get_arrays(surface_index)
		var verts: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
		var indices: PackedInt32Array = arrays[Mesh.ARRAY_INDEX] if arrays[Mesh.ARRAY_INDEX] != null else PackedInt32Array()
		for i in range(0, indices.size() - 2, 3):
			volume += verts[indices[i]].dot(verts[indices[i + 1]].cross(verts[indices[i + 2]]))
	return volume / 6.0


func _task_collision_policy() -> StringName:
	if current_task == null:
		return &"box"
	return StringName(current_task.collision_policy)


func _task_root_embed() -> float:
	if current_task == null:
		return float(root_embed_spin.value)
	return float(current_task.root_embed)


func _build_standard_asset() -> Resource:
	var asset: Resource = asset_script.new()
	var stable_id: Resource = stable_id_script.call("generate", StringName("std_" + String(current_task.category)))
	asset.stable_id = stable_id
	asset.display_name = String(current_task.display_name)
	asset.category = StringName(current_task.category)
	asset.task_id = StringName(current_task.task_id)
	asset.source_path = source_path if not source_path.is_empty() else "inline://pcg_standardization_window"
	asset.normalized_mesh = calibrated_mesh
	var aabb := calibrated_mesh.get_aabb()
	asset.dimensions = aabb.size
	asset.root_offset = Vector3.ZERO
	asset.root_embed = float(root_embed_spin.value)
	asset.outward_axis = _vec3_spins(outward_box).normalized()
	asset.up_axis = _vec3_spins(up_box).normalized()
	asset.uv_policy = StringName(current_task.uv_policy)
	asset.collision_policy = StringName(current_task.collision_policy)
	asset.producer = StringName(current_task.producer)
	asset.source_tool = String(current_task.source_tool)
	asset.source_prompt = String(current_task.source_prompt)
	asset.source_seed = String(current_task.source_seed)
	asset.lod1_target_faces = int(current_task.lod1_budget)
	asset.lod2_target_faces = int(current_task.lod2_budget)
	if whitebox_mesh == null:
		generate_whitebox()
	asset.whitebox_mesh = whitebox_mesh
	var warnings := PackedStringArray()
	for entry in last_acceptance.get("entries", []):
		if not bool(entry.get("blocking", false)) and not bool(entry.get("passed", false)):
			warnings.append(String(entry.get("label", "")))
	var notes := "硬性检查 0 项未通过"
	if not warnings.is_empty():
		notes += "；待处理参考项：%s" % ", ".join(warnings)
	notes += "；发布于 L1 资产标准化与验收窗口"
	asset.acceptance_report = {
		"verdict": "accepted_with_notes" if not warnings.is_empty() else "accepted",
		"checked_by": CHECKED_BY,
		"checked_at": Time.get_unix_time_from_system(),
		"notes": notes,
	}
	# 五类占用 AABB（核心正式 occupancy 字段，{slot: {"min","max"}}；
	# 只允许 solid/embed/exclusion/clearance/visual 五个槽位）。
	var occupancy := _build_occupancy()
	asset.set("occupancy", occupancy)
	last_occupancy = occupancy
	return asset


## 五类占用 AABB（资产局部坐标，min/max 显式序列化，与
## PCGStandardAsset.OCCUPANCY_SLOTS 语义一致）：
## solid 实体占用（网格 AABB）；embed 根部嵌入板区（表面 inward 侧）；
## exclusion 禁入区（embed 外扩 0.05，与核心推导一致）；
## clearance 通行净空（solid 外扩用户编辑的净空余量）；
## visual 视觉保护区（solid 外扩用户编辑的视觉扩展）。
func _build_occupancy() -> Dictionary:
	var mesh := active_mesh()
	var aabb: AABB = _inspect(mesh)["stats"]["aabb"]
	var embed := _embed_zone(aabb)
	return {
		"solid": _serialize_aabb(aabb),
		"embed": _serialize_aabb(embed),
		"exclusion": _serialize_aabb(embed.grow(EXCLUSION_MARGIN)),
		"clearance": _serialize_aabb(aabb.grow(float(clearance_spin.value))),
		"visual": _serialize_aabb(aabb.grow(float(visual_margin_spin.value))),
	}


func _embed_zone(aabb: AABB) -> AABB:
	var depth := maxf(minf(-aabb.position.z, aabb.end.z), 0.0)
	return AABB(aabb.position, Vector3(aabb.size.x, aabb.size.y, depth))


func _serialize_aabb(aabb: AABB) -> Dictionary:
	return {"min": [aabb.position.x, aabb.position.y, aabb.position.z],
		"max": [aabb.end.x, aabb.end.y, aabb.end.z]}


func _extract_occupancy(asset: Resource) -> Dictionary:
	var from_prop: Variant = asset.get("occupancy")
	if from_prop is Dictionary and not (from_prop as Dictionary).is_empty():
		return from_prop
	var from_report: Variant = asset.acceptance_report.get("occupancy", null)
	if from_report is Dictionary:
		return from_report
	return {}


func _dict_to_aabb(raw: Dictionary) -> AABB:
	var min_v := _vec3_from_variant(raw.get("min", []))
	var max_v := _vec3_from_variant(raw.get("max", []))
	return AABB(min_v, max_v - min_v)


func _vec3_from_variant(raw: Variant) -> Vector3:
	if raw is Array and (raw as Array).size() == 3:
		var items := raw as Array
		return Vector3(float(items[0]), float(items[1]), float(items[2]))
	return Vector3.ZERO


func _verify_occupancy(occupancy: Dictionary, mesh_aabb: AABB) -> Array:
	var problems := PackedStringArray()
	for slot in ["solid", "embed", "exclusion", "clearance", "visual"]:
		if not (occupancy.get(slot) is Dictionary):
			problems.append("occupancy 缺少 %s AABB" % slot)
	if not problems.is_empty():
		return Array(problems)
	var solid := _dict_to_aabb(occupancy["solid"])
	if (solid.position - mesh_aabb.position).length() > 0.01 \
		or (solid.size - mesh_aabb.size).length() > 0.01:
		problems.append("occupancy.solid 与网格 AABB 不一致")
	var expected_embed := _embed_zone(solid)
	if (_dict_to_aabb(occupancy["embed"]).position - expected_embed.position).length() > 0.01 \
		or (_dict_to_aabb(occupancy["embed"]).size - expected_embed.size).length() > 0.01:
		problems.append("occupancy.embed 板区不正确")
	var expected_exclusion := expected_embed.grow(EXCLUSION_MARGIN)
	if (_dict_to_aabb(occupancy["exclusion"]).position - expected_exclusion.position).length() > 0.01 \
		or (_dict_to_aabb(occupancy["exclusion"]).size - expected_exclusion.size).length() > 0.01:
		problems.append("occupancy.exclusion 未按嵌入区外扩 %.2f m" % EXCLUSION_MARGIN)
	# 净空/视觉保护区必须与表单编辑值一致（可见编辑→发布→重载全链核对）。
	var expected_clearance := solid.grow(float(clearance_spin.value))
	var clearance := _dict_to_aabb(occupancy["clearance"])
	if (clearance.position - expected_clearance.position).length() > 0.01 \
		or (clearance.size - expected_clearance.size).length() > 0.01:
		problems.append("occupancy.clearance 未按净空余量 %.3f m 扩展" % float(clearance_spin.value))
	var expected_visual := solid.grow(float(visual_margin_spin.value))
	var visual := _dict_to_aabb(occupancy["visual"])
	if (visual.position - expected_visual.position).length() > 0.01 \
		or (visual.size - expected_visual.size).length() > 0.01:
		problems.append("occupancy.visual 未按视觉扩展 %.3f m 扩展" % float(visual_margin_spin.value))
	return Array(problems)


func _apply_publish_manifest(manifest: Dictionary) -> void:
	var lods: Dictionary = manifest.get("lods", {})
	var faces: Dictionary = manifest.get("faces", {})
	for level in [1, 2]:
		var key := "lod%d" % level
		if not lods.has(key):
			continue
		var detail: Dictionary = lods[key]
		for entry in lod_entries:
			if int(entry.get("level", -1)) == level:
				entry["method"] = String(detail.get("method", entry.get("method", "")))
				entry["faces_out"] = int(detail.get("faces_out", entry.get("faces_out", 0)))
				entry["passed"] = int(entry.get("target", 0)) <= 0 or entry["faces_out"] <= int(entry["target"])
				entry["verdict"] = "%s %d→%d 面" % [entry["method"], int(entry.get("faces_in", 0)), entry["faces_out"]]
	_update_status_list()


func _restore_lod_entries(asset: Resource) -> void:
	lod_entries = []
	var budgets := [0, int(asset.lod1_target_faces), int(asset.lod2_target_faces)]
	var meshes := [asset.normalized_mesh, asset.lod1_mesh, asset.lod2_mesh]
	for level in 3:
		var faces := _face_count(meshes[level])
		var entry := {
			"level": level,
			"faces_in": _face_count(asset.normalized_mesh),
			"faces_out": faces,
			"target": int(budgets[level]),
			"method": "reloaded",
			"passed": int(budgets[level]) <= 0 or faces <= int(budgets[level]),
		}
		entry["verdict"] = "%d 面 / 预算 %d → %s" % [faces, int(budgets[level]),
			"通过" if entry["passed"] else "超预算"]
		lod_entries.append(entry)


func _build_acceptance() -> Dictionary:
	var entries: Array = []
	var mesh := active_mesh()
	if mesh == null:
		return {"entries": entries, "blocking_count": 0, "passed_count": 0}
	var report := _inspect(mesh)
	var stats: Dictionary = report["stats"]
	var aabb: AABB = stats["aabb"]
	entries.append(_entry("mesh_loaded", "网格已载入", true, true,
		"%d 面 / %d 顶点 / %d 材质槽" % [int(stats["triangles"]), int(stats["vertices"]), int(stats["material_slots"])]))
	# Inspector 错误逐条映射；issue 已覆盖的（零面积/NaN/预算/尺寸）不再重复。
	for line in report["errors"]:
		var text := String(line)
		if text.begins_with("mesh has") and text.contains("non-manifold"):
			entries.append(_entry("nonmanifold", "非流形边", true, false,
				"%d 条" % int(stats["non_manifold_edges"])))
		elif text.begins_with("mesh is open"):
			entries.append(_entry("closed", "封闭网格（无开放边）", true, false,
				"%d / %d 条开放边" % [int(stats["boundary_edges"]), int(stats["edges"])]))
	if not _entries_contain(entries, "nonmanifold"):
		entries.append(_entry("nonmanifold", "非流形边", true,
			int(stats["non_manifold_edges"]) == 0, "%d 条" % int(stats["non_manifold_edges"])))
	if not _entries_contain(entries, "closed"):
		entries.append(_entry("closed", "封闭网格（无开放边）", true,
			int(stats["boundary_edges"]) == 0, "%d 条开放边" % int(stats["boundary_edges"])))
	for issue in report["issues"]:
		var code := String(issue.get("code", "issue"))
		entries.append(_entry(code, _issue_label(code), String(issue.get("severity", "error")) == "error",
			false, String(issue.get("detail", "")), int(issue.get("surface", -1)), int(issue.get("triangle", -1))))
	entries.append(_entry("uv0", "UV0 存在", true, bool(stats["uv0_present"]),
		"已设置" if bool(stats["uv0_present"]) else "缺失"))
	if int(stats["boundary_edges"]) == 0 and int(stats["triangles"]) > 0:
		var volume := _signed_volume(mesh)
		entries.append(_entry("winding", "绕序/有向体积（顺时针朝外为负）", true,
			volume < -VOLUME_TOLERANCE, "有向体积 %0.6f m³" % volume))
	else:
		entries.append(_entry("winding", "绕序/有向体积（顺时针朝外为负）", true, true,
			"开放网格，跳过封闭体符号检查"))
	var root_ok := true
	var root_detail := ""
	if aabb.position.y > EPS:
		root_ok = false
		root_detail = "根部悬空：网格最低点 y=%0.4f > 0" % aabb.position.y
	else:
		var required := _task_root_embed() * aabb.size.y
		var embed := -aabb.position.y
		if embed < required * 0.5 - EPS:
			root_ok = false
			root_detail = "根部嵌入不足：%.4f m，低于所需 %.4f m 的一半" % [embed, required]
		elif embed < required - EPS:
			root_detail = "根部嵌入 %.4f m，低于建议 %.4f m（容忍）" % [embed, required]
		else:
			root_detail = "根部嵌入 %.4f m" % embed
	entries.append(_entry("root", "根部与原点（root_embed=%0.2f）" % _task_root_embed(), true, root_ok, root_detail))
	var warning_index := 0
	for warning in report["warnings"]:
		warning_index += 1
		entries.append(_entry("warning_%d" % warning_index, "警告", false, false, String(warning)))
	for host_kind in last_fit:
		var fit: Dictionary = last_fit[host_kind]
		entries.append(_entry("fit_%s" % fit["host_name"], "%s 主体试装" % fit["host_name"], false,
			bool(fit["ok"]), "嵌入 %.3f / 厚度 %.3f m" % [float(fit["embed_depth"]), float(fit["thickness"])]))
	var blocking := _blocking_entries({"entries": entries})
	var passed := 0
	for entry in entries:
		if bool(entry["passed"]):
			passed += 1
	return {"entries": entries, "blocking_count": blocking.size(), "passed_count": passed}


func _issue_label(code: String) -> String:
	match code:
		"zero_area_triangle":
			return "零面积面"
		"nan_vertices":
			return "NaN 顶点"
		"index_out_of_range":
			return "索引越界"
		"tri_budget_exceeded":
			return "LOD0 三角预算"
		"material_budget_exceeded":
			return "材质槽预算"
		"size_over_max":
			return "尺寸超上限"
		"size_under_min":
			return "尺寸低于下限"
	return code


func _entries_contain(entries: Array, id: String) -> bool:
	for entry in entries:
		if String(entry.get("id", "")) == id:
			return true
	return false


func _entry(id: String, label: String, blocking: bool, passed: bool, detail: String,
		surface: int = -1, triangle: int = -1) -> Dictionary:
	return {"id": id, "label": label, "blocking": blocking, "passed": passed,
		"detail": detail, "surface": surface, "triangle": triangle}


func _blocking_entries(report: Dictionary) -> Array:
	var result: Array = []
	for entry in report.get("entries", []):
		if bool(entry.get("blocking", false)) and not bool(entry.get("passed", false)):
			result.append(entry)
	return result


func _blocking_ids(report: Dictionary) -> Array:
	var ids: Array = []
	for entry in _blocking_entries(report):
		ids.append(String(entry["id"]))
	return ids


func _publish_result(ok: bool, error: String) -> Dictionary:
	return {"ok": ok, "error": error, "path": ""}


func _update_mesh_info() -> void:
	var mesh := active_mesh()
	if mesh == null:
		mesh_info_label.text = "未载入网格"
		return
	var stats: Dictionary = _inspect(mesh)["stats"]
	var aabb: AABB = stats["aabb"]
	mesh_info_label.text = "%s · %d 三角 / %d 顶点 / %.3f×%.3f×%.3f m" % [
		"校准后网格" if calibrated_mesh != null else "源网格",
		int(stats["triangles"]), int(stats["vertices"]), aabb.size.x, aabb.size.y, aabb.size.z]


func _update_calibration_label() -> void:
	if calibration.is_empty():
		calibration_label.text = "未校准"
		return
	var aabb: AABB = calibrated_mesh.get_aabb()
	calibration_label.text = "已校准：缩放 %0.4f，AABB 最低 y=%0.4f，尺寸 %.3f×%.3f×%.3f m" % [
		float(calibration.get("scale", 1.0)), aabb.position.y, aabb.size.x, aabb.size.y, aabb.size.z]


func _update_fit_label() -> void:
	if last_fit.is_empty():
		fit_label.text = "未试装"
		return
	var parts := PackedStringArray()
	for host_kind in last_fit:
		var fit: Dictionary = last_fit[host_kind]
		parts.append("%s:%s" % [fit["host_name"], "✓" if fit["ok"] else "✗"])
	fit_label.text = "试装 " + " / ".join(parts)


func _update_status_list() -> void:
	status_list.clear()
	if whitebox_report.is_empty():
		status_list.add_item("白盒：未生成")
	else:
		var size: Vector3 = whitebox_report["size"]
		status_list.add_item("白盒：%.3f×%.3f×%.3f m（%d 三角）" % [size.x, size.y, size.z, int(whitebox_report["tri_count"])])
	if collision_entries.is_empty():
		status_list.add_item("碰撞：未生成（策略 %s）" % String(_task_collision_policy()))
	else:
		for entry in collision_entries:
			status_list.add_item("碰撞（%s）：%s" % [entry["policy"], entry["description"]])
	if lod_entries.is_empty():
		status_list.add_item("LOD：未生成")
	else:
		for entry in lod_entries:
			status_list.add_item("LOD%d：%s" % [entry["level"], entry.get("verdict", "")])
	if last_occupancy.is_empty():
		status_list.add_item("占用：未生成（五类 AABB）")
	else:
		status_list.add_item("占用：五类 AABB（净空 %.2f / 视觉 %.2f m）"
			% [float(clearance_spin.value), float(visual_margin_spin.value)])


func _refresh_report_view() -> void:
	report_list.clear()
	var entries: Array = last_acceptance.get("entries", [])
	for entry in entries:
		var mark := "✓" if bool(entry["passed"]) else "✗"
		var blocking := "[硬性]" if bool(entry["blocking"]) else "[参考]"
		report_list.add_item("%s %s %s — %s" % [mark, blocking, entry["label"], entry["detail"]])
	var blocking := _blocking_entries(last_acceptance)
	publish_button.disabled = not blocking.is_empty() or active_mesh() == null \
		or current_task == null or calibrated_mesh == null
	calibrate_button.disabled = source_mesh == null
	fit_button.disabled = active_mesh() == null
	whitebox_button.disabled = active_mesh() == null
	collision_button.disabled = active_mesh() == null
	lod_button.disabled = active_mesh() == null


func _set_status(text: String) -> void:
	if status_label != null:
		status_label.text = text


func _on_task_selected(index: int) -> void:
	if index < 0 or index >= tasks.size():
		return
	current_task = tasks[index]
	_set_vec3_spins(target_size_box, current_task.target_size)
	root_embed_spin.set_value_no_signal(float(current_task.root_embed))
	_set_vec3_spins(outward_box, current_task.outward_axis)
	_set_vec3_spins(up_box, current_task.up_axis)
	calibrated_mesh = null
	calibration = {}
	whitebox_mesh = null
	whitebox_report = {}
	collision_entries = []
	lod_entries = []
	last_fit = {}
	last_occupancy = {}
	reloaded_asset = null
	_update_mesh_info()
	_update_calibration_label()
	_update_fit_label()
	_update_status_list()
	run_acceptance()
	_set_status("已选择任务 %s" % String(current_task.task_id))


func _select_current_in_option() -> void:
	if current_task == null:
		return
	for index in tasks.size():
		if StringName(tasks[index].task_id) == StringName(current_task.task_id):
			task_option.select(index)
			return


func _vec3_spins(box: HBoxContainer) -> Vector3:
	var spins: Array = []
	for child in box.get_children():
		if child is SpinBox:
			spins.append(child)
	if spins.size() < 3:
		return Vector3.ZERO
	return Vector3(spins[0].value, spins[1].value, spins[2].value)


func _set_vec3_spins(box: HBoxContainer, value: Vector3) -> void:
	var spins: Array = []
	for child in box.get_children():
		if child is SpinBox:
			spins.append(child)
	if spins.size() < 3:
		return
	spins[0].set_value_no_signal(value.x)
	spins[1].set_value_no_signal(value.y)
	spins[2].set_value_no_signal(value.z)


func _build_ui() -> void:
	var root := VBoxContainer.new()
	root.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	root.add_theme_constant_override("separation", 6)
	add_child(root)

	var task_row := HBoxContainer.new()
	root.add_child(task_row)
	var task_label := Label.new()
	task_label.text = "L0 任务"
	task_label.custom_minimum_size = Vector2(90, 0)
	task_row.add_child(task_label)
	task_option = OptionButton.new()
	task_option.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	task_option.item_selected.connect(_on_task_selected)
	task_row.add_child(task_option)
	refresh_task_button = _small_button(task_row, "刷新任务", _on_refresh_tasks)

	var source_row := HBoxContainer.new()
	root.add_child(source_row)
	var source_label_row := Label.new()
	source_label_row.text = "候选资源"
	source_label_row.custom_minimum_size = Vector2(90, 0)
	source_row.add_child(source_label_row)
	source_edit = LineEdit.new()
	source_edit.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	source_edit.placeholder_text = "res:// 或 user:// 路径，Mesh 或 PackedScene"
	source_row.add_child(source_edit)
	load_button = _small_button(source_row, "加载", _on_load_pressed)
	mesh_info_label = Label.new()
	mesh_info_label.text = "未载入网格"
	mesh_info_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	root.add_child(mesh_info_label)

	var calibrate_group := VBoxContainer.new()
	calibrate_group.add_theme_constant_override("separation", 4)
	root.add_child(calibrate_group)
	var calibrate_heading := Label.new()
	calibrate_heading.text = "尺寸 / 根部 / 轴向校准"
	calibrate_heading.add_theme_font_size_override("font_size", 15)
	calibrate_group.add_child(calibrate_heading)
	target_size_box = _vec3_row(calibrate_group, "目标尺寸 (m)", 0.01, 1000.0, 0.01)
	_set_vec3_spins(target_size_box, Vector3(1.0, 2.0, 0.3))
	root_embed_spin = _spin_row(calibrate_group, "根部嵌入比例", 0.0, 1.0, 0.01, 0.12)
	clearance_spin = _spin_row(calibrate_group, "净空余量 (m)", 0.0, 10.0, 0.01, 0.05)
	visual_margin_spin = _spin_row(calibrate_group, "视觉保护区扩展 (m)", 0.0, 10.0, 0.01, 0.15)
	outward_box = _vec3_row(calibrate_group, "外法线轴", -1.0, 1.0, 0.05)
	_set_vec3_spins(outward_box, Vector3(0.0, 0.0, 1.0))
	up_box = _vec3_row(calibrate_group, "上方向轴", -1.0, 1.0, 0.05)
	_set_vec3_spins(up_box, Vector3(0.0, 1.0, 0.0))
	calibrate_button = Button.new()
	calibrate_button.text = "执行校准"
	calibrate_button.pressed.connect(_on_calibrate_pressed)
	calibrate_group.add_child(calibrate_button)
	calibration_label = Label.new()
	calibration_label.text = "未校准"
	calibration_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	calibrate_group.add_child(calibration_label)

	var fit_row := HBoxContainer.new()
	root.add_child(fit_row)
	var fit_title := Label.new()
	fit_title.text = "主体试装"
	fit_title.custom_minimum_size = Vector2(90, 0)
	fit_row.add_child(fit_title)
	host_option = OptionButton.new()
	host_option.add_item("平面主体")
	host_option.add_item("圆柱主体")
	host_option.add_item("半球圆柱主体")
	host_option.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	fit_row.add_child(host_option)
	fit_button = _small_button(fit_row, "试装", _on_fit_pressed)
	fit_label = Label.new()
	fit_label.text = "未试装"
	fit_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	root.add_child(fit_label)

	var gen_row := HBoxContainer.new()
	root.add_child(gen_row)
	whitebox_button = _small_button(gen_row, "生成白盒", _on_whitebox_pressed)
	collision_button = _small_button(gen_row, "生成碰撞", _on_collision_pressed)
	lod_button = _small_button(gen_row, "LOD 状态", _on_lod_pressed)
	status_list = ItemList.new()
	status_list.custom_minimum_size = Vector2(0, 64)
	root.add_child(status_list)

	var report_heading := Label.new()
	report_heading.text = "验收报告"
	report_heading.add_theme_font_size_override("font_size", 15)
	root.add_child(report_heading)
	report_list = ItemList.new()
	report_list.custom_minimum_size = Vector2(0, 150)
	report_list.size_flags_vertical = Control.SIZE_EXPAND_FILL
	root.add_child(report_list)

	var publish_row := HBoxContainer.new()
	root.add_child(publish_row)
	var publish_label := Label.new()
	publish_label.text = "发布目录"
	publish_label.custom_minimum_size = Vector2(90, 0)
	publish_row.add_child(publish_label)
	publish_dir_edit = LineEdit.new()
	publish_dir_edit.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	publish_dir_edit.text = DEFAULT_PUBLISH_DIRECTORY
	publish_row.add_child(publish_dir_edit)
	publish_button = _small_button(publish_row, "发布", _on_publish_pressed)
	reload_button = _small_button(publish_row, "重载", _on_reload_pressed)

	status_label = Label.new()
	status_label.text = ""
	status_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	root.add_child(status_label)
	_refresh_report_view()


func _small_button(parent: Control, text: String, callback: Callable) -> Button:
	var button := Button.new()
	button.text = text
	button.pressed.connect(callback)
	parent.add_child(button)
	return button


func _spin_row(parent: Control, label_text: String, minimum: float, maximum: float, step: float, initial: float) -> SpinBox:
	var row := HBoxContainer.new()
	parent.add_child(row)
	var label := Label.new()
	label.text = label_text
	label.custom_minimum_size = Vector2(150, 0)
	row.add_child(label)
	var spin := SpinBox.new()
	spin.min_value = minimum
	spin.max_value = maximum
	spin.step = step
	spin.value = initial
	spin.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(spin)
	return spin


func _vec3_row(parent: Control, label_text: String, minimum: float, maximum: float, step: float) -> HBoxContainer:
	var row := HBoxContainer.new()
	parent.add_child(row)
	var label := Label.new()
	label.text = label_text
	label.custom_minimum_size = Vector2(150, 0)
	row.add_child(label)
	var box := HBoxContainer.new()
	box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	box.set_meta("vec3", true)
	for axis in 3:
		var spin := SpinBox.new()
		spin.min_value = minimum
		spin.max_value = maximum
		spin.step = step
		spin.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		box.add_child(spin)
	row.add_child(box)
	return box


func _on_refresh_tasks() -> void:
	refresh_task_list()


func _on_load_pressed() -> void:
	load_source_from_path(source_edit.text)


func _on_calibrate_pressed() -> void:
	calibrate()


func _on_fit_pressed() -> void:
	trial_fit(maxi(host_option.selected, 0))


func _on_whitebox_pressed() -> void:
	generate_whitebox()


func _on_collision_pressed() -> void:
	generate_collision()


func _on_lod_pressed() -> void:
	generate_lod_status()


func _on_publish_pressed() -> void:
	publish()


func _on_reload_pressed() -> void:
	reload_published()
