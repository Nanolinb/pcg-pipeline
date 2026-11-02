class_name PCGStandardAssetChecks
extends RefCounted

# v0.16 L1 标准资产与试装发布专项测试。
# 单源随共享包分发；standard_asset_check.gd（-s 入口）与
# scripts/tests/run_standard_asset_test.gd 均调用 run()。
# 覆盖：发布/重载往返、自动 LOD 真实减面与显式 LOD、试装变换（三种宿主）、
# 白盒与 box/convex/concave 碰撞输出、缺失依赖拒绝
# （缺 Mesh / 缺验收报告 / 重复 ID / 缺网格文件 / 自动 LOD 能力失败）。

const LOG_PREFIX := "STDASSET"

var checks_run: int = 0
var failures: Array[String] = []
var _prefix: String = LOG_PREFIX


func run(log_prefix: String = LOG_PREFIX) -> Dictionary:
	_prefix = log_prefix
	_check_model_validation()
	_check_lod_real_decimation()
	_check_publish_reload_roundtrip()
	_check_explicit_lod_fallback()
	_check_preview_transform_plane()
	_check_preview_three_hosts()
	_check_whitebox_and_collision()
	_check_missing_dependencies()
	return {"checks_run": checks_run, "failures": failures.duplicate()}


func _record(ok: bool, name: String, detail: String = "") -> void:
	checks_run += 1
	var label := name + ("" if detail.is_empty() else " (" + detail + ")")
	if ok:
		print("%s_CHECK_PASS: %s" % [_prefix, label])
	else:
		failures.append(label)
		print("%s_CHECK_FAIL: %s" % [_prefix, label])


func _errors_contain(errors: Array, needle: String) -> bool:
	for e in errors:
		if String(e).contains(needle):
			return true
	return false


# ------------------------------------------------------------------ 测试夹具

func _grid_mesh(segments: int = 16) -> ArrayMesh:
	# segments×segments 网格平面（x,z ∈ [0,1]，512 三角形 @16），顶点有真实起伏，
	# 保证减面是几何操作而非边界特例。
	var surface_tool := SurfaceTool.new()
	surface_tool.begin(Mesh.PRIMITIVE_TRIANGLES)
	for z in segments:
		for x in segments:
			var p00 := Vector3(float(x) / segments, 0.02 * sin(x * 1.7) * cos(z * 2.3), float(z) / segments)
			var p10 := Vector3(float(x + 1) / segments, 0.02 * sin((x + 1) * 1.7) * cos(z * 2.3), float(z) / segments)
			var p01 := Vector3(float(x) / segments, 0.02 * sin(x * 1.7) * cos((z + 1) * 2.3), float(z + 1) / segments)
			var p11 := Vector3(float(x + 1) / segments, 0.02 * sin((x + 1) * 1.7) * cos((z + 1) * 2.3), float(z + 1) / segments)
			surface_tool.add_vertex(p00)
			surface_tool.add_vertex(p10)
			surface_tool.add_vertex(p11)
			surface_tool.add_vertex(p00)
			surface_tool.add_vertex(p11)
			surface_tool.add_vertex(p01)
	surface_tool.index()
	surface_tool.generate_normals()
	return surface_tool.commit()


func _face_count(mesh: ArrayMesh) -> int:
	if mesh == null:
		return 0
	var faces := 0
	for surface_index in mesh.get_surface_count():
		var arrays := mesh.surface_get_arrays(surface_index)
		var indices: PackedInt32Array = arrays[Mesh.ARRAY_INDEX]
		if indices.is_empty():
			faces += arrays[Mesh.ARRAY_VERTEX].size() / 3
		else:
			faces += indices.size() / 3
	return faces


func _valid_asset(asset_id: String = "asset_test_door") -> PCGStandardAsset:
	var asset := PCGStandardAsset.new()
	asset.stable_id = PCGStableId.new()
	asset.stable_id.id = StringName(asset_id)
	asset.display_name = "测试资产"
	asset.category = &"door"
	asset.task_id = &"task_test_door"
	asset.source_path = "res://assets/tasks/draft_door_a.glb"
	asset.normalized_mesh = _grid_mesh()
	asset.producer = &"ai"
	asset.source_tool = "test-tool"
	asset.source_prompt = "test prompt"
	asset.source_seed = "test-seed"
	asset.uv_policy = &"texel_density"
	asset.collision_policy = &"convex"
	asset.acceptance_report = {
		"verdict": "accepted",
		"checked_by": "qa-bot",
		"checked_at": "2026-11-02",
		"notes": "尺寸/接口/预算全部达标",
	}
	return asset


func _test_dir(sub: String) -> String:
	var dir := "user://pcg_standard_asset_test/" + sub
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(dir))
	# 清理历史运行残留，保证断言检查的是本次行为。
	var access := DirAccess.open(dir)
	if access != null:
		for file_name in access.get_files():
			access.remove(file_name)
	return dir


# ------------------------------------------------------------------ 模型校验

func _check_model_validation() -> void:
	var blank := PCGStandardAsset.new()
	var errors := blank.validation_errors()
	_record(_errors_contain(errors, "stable_id") and _errors_contain(errors, "display_name")
		and _errors_contain(errors, "task reference") and _errors_contain(errors, "source_path")
		and _errors_contain(errors, "normalized_mesh") and _errors_contain(errors, "acceptance_report"),
		"validation: blank asset fails publish with per-field errors", "%d errors" % errors.size())

	var valid := _valid_asset()
	_record(valid.validation_errors().is_empty(),
		"validation: complete asset passes publish validation")

	var no_report := _valid_asset("asset_no_report")
	no_report.acceptance_report = {}
	_record(_errors_contain(no_report.validation_errors(), "acceptance_report"),
		"validation: missing acceptance report rejected")

	var bad_verdict := _valid_asset("asset_bad_verdict")
	bad_verdict.acceptance_report = {"verdict": "whatever", "checked_by": "qa", "checked_at": "d", "notes": "n"}
	_record(_errors_contain(bad_verdict.validation_errors(), "verdict"),
		"validation: unknown verdict rejected")

	var rejected := _valid_asset("asset_rejected")
	rejected.acceptance_report["verdict"] = "rejected"
	_record(_errors_contain(rejected.validation_errors(), "rejected"),
		"validation: rejected verdict blocked from publish")

	var ai_no_trace := _valid_asset("asset_ai_no_trace")
	ai_no_trace.source_tool = ""
	ai_no_trace.source_prompt = ""
	ai_no_trace.source_seed = ""
	var trace_errors := ai_no_trace.validation_errors()
	_record(_errors_contain(trace_errors, "source_tool") and _errors_contain(trace_errors, "source_prompt")
		and _errors_contain(trace_errors, "source_seed"),
		"validation: ai asset without provenance rejected")

	# 热重载场景：原始 dict 中策略字段为 null（反序列化中间态），
	# from_dict 必须报错而不是崩溃或默默通过。
	var hot_data := _valid_asset("asset_hot").to_dict()
	hot_data["uv_policy"] = null
	hot_data["collision_policy"] = null
	var hot := PCGStandardAsset.new()
	var hot_problems := hot.from_dict(hot_data)
	_record(_errors_contain(hot_problems, "uv_policy") and _errors_contain(hot_problems, "collision_policy"),
		"validation: null policy fields during reload report errors without crashing")

	var future := PCGStandardAsset.new()
	var future_problems := future.from_dict({"format_version": 99, "stable_id": {"id": "asset_future"}})
	_record(not future_problems.is_empty() and String(future.asset_id()).is_empty(),
		"validation: future format_version rejected without half-built asset",
		future_problems[0] if not future_problems.is_empty() else "")


# ---------------------------------------------------------- LOD 真实减面

func _check_lod_real_decimation() -> void:
	var mesh := _grid_mesh()
	var cap: Dictionary = PCGMeshLod.capability(mesh)
	_record(cap["ok"] and cap["faces"] == 512, "lod: capability reports 512 faces", "faces=%d" % cap["faces"])

	var decimated: Dictionary = PCGMeshLod.decimate(mesh, 120)
	_record(decimated["ok"] and decimated["method"] == "vertex_clustering"
		and decimated["faces_out"] < decimated["faces_in"] and decimated["faces_out"] <= 120,
		"lod: decimation truly reduces faces", "512 -> %d (cell %.4f)" % [decimated["faces_out"], decimated["cell_size"]])
	var out_mesh: ArrayMesh = decimated["mesh"]
	_record(out_mesh != null and out_mesh != mesh and _face_count(out_mesh) == decimated["faces_out"],
		"lod: decimated mesh is a new real mesh, not the LOD0 reference")
	# 真实性的几何证据：减面后顶点数严格少于原网格。
	var original_arrays := mesh.surface_get_arrays(0)
	var reduced_arrays := out_mesh.surface_get_arrays(0)
	var original_vertices: int = (original_arrays[Mesh.ARRAY_VERTEX] as PackedVector3Array).size()
	var reduced_vertices: int = (reduced_arrays[Mesh.ARRAY_VERTEX] as PackedVector3Array).size()
	_record(reduced_vertices < original_vertices,
		"lod: decimated vertex count strictly smaller", "%d -> %d" % [original_vertices, reduced_vertices])

	var passthrough: Dictionary = PCGMeshLod.decimate(mesh, 5000)
	_record(passthrough["ok"] and passthrough["method"] == "passthrough_below_budget"
		and passthrough["faces_out"] == 512,
		"lod: below-budget passthrough is explicit, not silent")

	var empty := ArrayMesh.new()
	var no_cap: Dictionary = PCGMeshLod.capability(empty)
	_record(not no_cap["ok"] and _errors_contain(no_cap["errors"], "no surfaces"),
		"lod: empty mesh fails capability check")

	var lines_tool := SurfaceTool.new()
	lines_tool.begin(Mesh.PRIMITIVE_LINES)
	lines_tool.add_vertex(Vector3.ZERO)
	lines_tool.add_vertex(Vector3.RIGHT)
	var lines_mesh := lines_tool.commit()
	var lines_cap: Dictionary = PCGMeshLod.capability(lines_mesh)
	_record(not lines_cap["ok"] and _errors_contain(lines_cap["errors"], "PRIMITIVE_TRIANGLES"),
		"lod: non-triangle primitive fails capability check")
	var lines_decimate: Dictionary = PCGMeshLod.decimate(lines_mesh, 10)
	_record(not lines_decimate["ok"] and _errors_contain(lines_decimate["errors"], "explicit LOD"),
		"lod: capability failure tells caller to supply explicit LOD")


# ---------------------------------------------------------- 发布/重载

func _check_publish_reload_roundtrip() -> void:
	var store := PCGStandardAssetStore.new()
	var dir := _test_dir("roundtrip")
	var asset := _valid_asset("asset_roundtrip")
	asset.root_embed = 0.1
	asset.dimensions = Vector3(1.0, 0.1, 1.0)
	var published: Dictionary = store.publish(asset, dir)
	_record(published["ok"], "publish: valid asset publishes", String(published.get("path", "")))
	if not published["ok"]:
		_record(false, "publish: aborted", "; ".join(published["errors"]))
		return
	var path: String = published["path"]
	_record(FileAccess.file_exists(path)
		and FileAccess.file_exists(dir + "/asset_roundtrip.lod0.mesh.res")
		and FileAccess.file_exists(dir + "/asset_roundtrip.lod1.mesh.res")
		and FileAccess.file_exists(dir + "/asset_roundtrip.lod2.mesh.res")
		and FileAccess.file_exists(dir + "/asset_roundtrip.whitebox.mesh.res"),
		"publish: JSON + all four mesh files on disk")
	_record(not FileAccess.file_exists(path + ".tmp"),
		"publish: no temp residue after commit")

	var manifest: Dictionary = store.last_publish_manifest
	var lods: Dictionary = manifest["lods"]
	_record(lods["lod1"]["method"] == "vertex_clustering" and lods["lod2"]["method"] == "vertex_clustering"
		and int(lods["lod1"]["faces_out"]) < 512 and int(lods["lod2"]["faces_out"]) < int(lods["lod1"]["faces_out"]),
		"publish: auto LOD manifest shows real reduction",
		"lod1=%s lod2=%s" % [lods["lod1"]["faces_out"], lods["lod2"]["faces_out"]])
	_record(String(lods["lod2"].get("warning", "")).contains("unreachable"),
		"publish: best-effort LOD below target is disclosed in manifest, not silent",
		String(lods["lod2"].get("warning", "")))

	var loaded: Dictionary = store.load_asset(path)
	var asset2: PCGStandardAsset = loaded["asset"]
	_record(loaded["ok"] and asset2 != null, "reload: published asset loads")
	if not loaded["ok"]:
		_record(false, "reload: aborted", "; ".join(loaded["errors"]))
		return
	_record(String(asset2.asset_id()) == "asset_roundtrip" and asset2.display_name == "测试资产"
		and asset2.category == &"door" and String(asset2.task_id) == "task_test_door"
		and asset2.source_path == "res://assets/tasks/draft_door_a.glb"
		and asset2.uv_policy == &"texel_density" and asset2.collision_policy == &"convex"
		and asset2.producer == &"ai" and asset2.source_seed == "test-seed"
		and asset2.dimensions == Vector3(1.0, 0.1, 1.0)
		and is_equal_approx(asset2.root_embed, 0.1),
		"reload: every metadata field round-trips")
	_record(asset2.acceptance_report == asset.acceptance_report,
		"reload: acceptance report round-trips")
	_record(asset2.lod_status == PackedStringArray(["auto", "auto"]),
		"reload: lod status recorded as auto")
	_record(asset2.normalized_mesh != null and asset2.lod1_mesh != null
		and asset2.lod2_mesh != null and asset2.whitebox_mesh != null,
		"reload: all four meshes attached")
	_record(_face_count(asset2.normalized_mesh) == 512
		and _face_count(asset2.lod1_mesh) < 512 and _face_count(asset2.lod2_mesh) < 512,
		"reload: reloaded LODs keep real decimated geometry")
	_record(asset2.normalized_mesh != asset2.lod1_mesh and asset2.lod1_mesh != asset2.lod2_mesh,
		"reload: LOD meshes are distinct resources, no silent copy")
	var whitebox_aabb: AABB = asset2.whitebox_mesh.get_aabb()
	_record(is_equal_approx(whitebox_aabb.size.x, 1.0) and is_equal_approx(whitebox_aabb.size.z, 1.0),
		"reload: whitebox matches asset AABB")

	# 重复 ID 拒绝：目录内已存在，绝不覆盖。
	var duplicate := _valid_asset("asset_roundtrip")
	duplicate.display_name = "伪造副本"
	var dup_result: Dictionary = store.publish(duplicate, dir)
	_record(not dup_result["ok"] and _errors_contain(dup_result["errors"], "duplicate asset id"),
		"publish: duplicate id refused without overwrite")
	var still_loaded: Dictionary = store.load_asset(path)
	_record(still_loaded["ok"] and (still_loaded["asset"] as PCGStandardAsset).display_name == "测试资产",
		"publish: original asset untouched after duplicate refusal")

	# 列表：重复/坏文件有报告。
	var listed := store.list_assets(dir)
	_record(listed.size() == 1 and store.last_report.is_empty(),
		"list: single clean asset lists cleanly", "count=%d" % listed.size())


# ------------------------------------------------- 自动 LOD 失败 → 显式 LOD

func _check_explicit_lod_fallback() -> void:
	var store := PCGStandardAssetStore.new()
	var dir := _test_dir("explicit_lod")
	var lines_tool := SurfaceTool.new()
	lines_tool.begin(Mesh.PRIMITIVE_TRIANGLE_STRIP)
	for i in 8:
		lines_tool.add_vertex(Vector3(float(i) * 0.1, 0.0, 0.0))
		lines_tool.add_vertex(Vector3(float(i) * 0.1, 0.1, 0.1))
	var strip_mesh := lines_tool.commit()
	var asset := _valid_asset("asset_strip")
	asset.normalized_mesh = strip_mesh
	var refused: Dictionary = store.publish(asset, dir)
	_record(not refused["ok"] and _errors_contain(refused["errors"], "explicit LOD"),
		"explicit: auto LOD capability failure refuses publish with explicit-LOD hint",
		"; ".join(refused["errors"]).substr(0, 90) if not refused["errors"].is_empty() else "")
	_record(not FileAccess.file_exists(dir + "/asset_strip.asset.json"),
		"explicit: refused publish leaves no JSON on disk")

	# 提供显式 LOD 后发布成功，状态标记 explicit。
	var asset2 := _valid_asset("asset_strip")
	asset2.normalized_mesh = strip_mesh
	asset2.lod1_mesh = _grid_mesh(4)
	asset2.lod2_mesh = _grid_mesh(2)
	var published: Dictionary = store.publish(asset2, dir)
	_record(published["ok"], "explicit: publish succeeds with explicit LODs")
	var loaded: Dictionary = store.load_asset(published["path"] if published["ok"] else "")
	if loaded["ok"]:
		var asset3: PCGStandardAsset = loaded["asset"]
		_record(asset3.lod_status == PackedStringArray(["explicit", "explicit"]),
			"explicit: lod status recorded as explicit")
		_record(_face_count(asset3.lod1_mesh) == 32 and _face_count(asset3.lod2_mesh) == 8,
			"explicit: reloaded explicit LODs keep their own geometry")
	else:
		_record(false, "explicit: reload after explicit publish", "; ".join(loaded["errors"]))


# ---------------------------------------------------------- 试装变换（平面）

func _check_preview_transform_plane() -> void:
	var host := PCGSurfaceHostData.new()
	host.host_id = &"host_plane_test"
	host.configure_plane(Vector3(6.0, 4.6, 0.36))
	host.host_transform = Transform3D(Basis.from_euler(Vector3(0.0, 0.4, 0.0)), Vector3(1.0, 2.0, 3.0))
	var asset := _valid_asset("asset_preview")
	asset.root_embed = 0.15
	var anchor := Vector2(0.8, -0.6)

	var preview := PCGSurfacePreview.build_surface_preview(asset, host, anchor)
	_record(preview != null and preview.mesh == asset.normalized_mesh,
		"preview: builds MeshInstance3D with LOD0 by default")
	var frame := host.surface_transform(anchor)
	var expected_origin := frame.origin + frame.basis * asset.root_offset \
		- frame.basis.z.normalized() * asset.root_embed
	_record(preview.transform.origin.distance_to(expected_origin) < 0.0001,
		"preview: origin = surface anchor - normal * root_embed",
		"origin=%s" % preview.transform.origin)
	_record(preview.transform.basis.z.normalized().distance_to(frame.basis.z.normalized()) < 0.001,
		"preview: outward basis aligns with surface normal")
	# 轴对齐：资产默认 outward=BACK、up=UP，对齐后 -Z 应指向表面法向。
	var mapped := preview.transform.basis * Vector3.BACK
	_record(mapped.distance_to(frame.basis.z.normalized()) < 0.001,
		"preview: asset outward axis maps onto surface normal")

	# 世界射线往返：从试装位置沿法向发射，应命中同一锚点。
	var hit := host.surface_raycast(preview.transform.origin, frame.basis.z.normalized())
	_record(not hit.is_empty() and (hit["anchor"] as Vector2).distance_to(anchor) < 0.001,
		"preview: raycast from preview origin returns the same anchor")

	# 白盒、LOD 与碰撞选项。
	var asset_with_lods := _valid_asset("asset_preview_lods")
	asset_with_lods.lod1_mesh = PCGMeshLod.decimate(asset_with_lods.normalized_mesh, 100)["mesh"]
	var whitebox := PCGSurfacePreview.build_surface_preview(asset_with_lods, host, anchor, {"whitebox": true})
	_record((whitebox.mesh == asset_with_lods.whitebox_mesh and asset_with_lods.whitebox_mesh != null)
		or whitebox.mesh.get_aabb().size.distance_to(asset_with_lods.mesh_aabb().size) < 0.0001,
		"preview: whitebox option uses whitebox mesh")
	var lod1 := PCGSurfacePreview.build_surface_preview(asset_with_lods, host, anchor, {"lod": 1})
	_record(lod1.mesh == asset_with_lods.lod1_mesh and lod1.mesh != asset_with_lods.normalized_mesh,
		"preview: lod option selects lod1 mesh, distinct from LOD0")
	var no_collision := PCGSurfacePreview.build_surface_preview(asset_with_lods, host, anchor, {"collision": false})
	var body_count := 0
	for child in no_collision.get_children():
		if child is StaticBody3D:
			body_count += 1
	_record(body_count == 0, "preview: collision=false omits collision body")
	preview.free()
	whitebox.free()
	lod1.free()
	no_collision.free()


# ---------------------------------------------------------- 三种宿主试装

func _check_preview_three_hosts() -> void:
	var asset := _valid_asset("asset_hosts")
	asset.root_embed = 0.1
	var plane := PCGSurfaceHostData.new()
	plane.configure_plane(Vector3(6.0, 4.6, 0.36))
	var cylinder := PCGSurfaceHostData.new()
	cylinder.configure_cylinder(1.35, 3.8, 0.7, false)
	var dome := PCGSurfaceHostData.new()
	dome.configure_cylinder(1.35, 3.8, 0.7, true)
	var hosts: Array = [["plane", plane], ["cylinder", cylinder], ["dome_cylinder", dome]]
	for entry in hosts:
		var label: String = entry[0]
		var host: PCGSurfaceHostData = entry[1]
		host.host_id = StringName("host_" + label)
		host.host_transform = Transform3D(Basis.from_euler(Vector3(0.15, 0.7, 0.0)),
			Vector3(-1.0, 1.5, 2.0))
		var anchor := Vector2(0.45, 0.3)
		var frame := host.surface_transform(anchor)
		var preview := PCGSurfacePreview.build_surface_preview(asset, host, anchor)
		var expected_origin := frame.origin - frame.basis.z.normalized() * asset.root_embed
		_record(preview != null
			and preview.transform.origin.distance_to(expected_origin) < 0.001,
			"hosts[%s]: preview sits on surface with root embed" % label)
		_record(preview != null
			and preview.transform.basis.z.normalized().distance_to(frame.basis.z.normalized()) < 0.001,
			"hosts[%s]: preview normal matches surface normal" % label)
		var hit := host.surface_raycast(preview.transform.origin, frame.basis.z.normalized())
		_record(not hit.is_empty() and (hit["anchor"] as Vector2).distance_to(anchor) < 0.01,
			"hosts[%s]: raycast round-trips to the same anchor" % label)
		# 换锚点：试装位置必须跟着表面走（圆柱上不同弧长位置）。
		var anchor2 := Vector2(-0.9, -0.4)
		var preview2 := PCGSurfacePreview.build_surface_preview(asset, host, anchor2)
		var frame2 := host.surface_transform(anchor2)
		_record(preview2.transform.origin.distance_to(frame2.origin - frame2.basis.z.normalized() * asset.root_embed) < 0.001
			and preview2.transform.origin.distance_to(preview.transform.origin) > 0.01,
			"hosts[%s]: different anchors give different placements" % label)
		preview.free()
		preview2.free()


# ---------------------------------------------------------- 白盒与碰撞

func _check_whitebox_and_collision() -> void:
	var asset := _valid_asset("asset_collision")
	var aabb := asset.mesh_aabb()
	var whitebox := PCGSurfacePreview.make_whitebox_mesh(aabb)
	_record(_face_count(whitebox) == 12 and whitebox.get_aabb().size.distance_to(aabb.size) < 0.0001,
		"whitebox: 12-triangle box matching asset AABB")

	asset.collision_policy = &"box"
	var box_shape := PCGSurfacePreview.build_collision_shape(asset)
	_record(box_shape is BoxShape3D and (box_shape as BoxShape3D).size.distance_to(aabb.size) < 0.0001,
		"collision: box policy yields AABB-sized BoxShape3D")

	asset.collision_policy = &"convex"
	var convex_shape := PCGSurfacePreview.build_collision_shape(asset)
	_record(convex_shape is ConvexPolygonShape3D
		and (convex_shape as ConvexPolygonShape3D).points.size() == asset.normalized_mesh.surface_get_arrays(0)[Mesh.ARRAY_VERTEX].size(),
		"collision: convex policy yields hull from real mesh vertices")

	asset.collision_policy = &"concave"
	var concave_shape := PCGSurfacePreview.build_collision_shape(asset)
	_record(concave_shape is ConcavePolygonShape3D
		and (concave_shape as ConcavePolygonShape3D).get_faces().size() == 512 * 3,
		"collision: concave policy yields per-triangle faces")

	asset.collision_policy = &"none"
	_record(PCGSurfacePreview.build_collision_shape(asset) == null,
		"collision: none policy yields no shape")
	var preview := PCGSurfacePreview.build_surface_preview(asset, PCGSurfaceHostData.new(), Vector2.ZERO)
	var has_body := false
	for child in preview.get_children():
		if child is StaticBody3D:
			has_body = true
	_record(not has_body, "collision: none policy adds no body to preview")

	# 碰撞体随试装挂出，box 策略下形状中心对齐 AABB 中心。
	asset.collision_policy = &"box"
	var host := PCGSurfaceHostData.new()
	host.configure_plane(Vector3(6.0, 4.6, 0.36))
	var preview2 := PCGSurfacePreview.build_surface_preview(asset, host, Vector2(0.3, 0.2))
	var found := false
	for child in preview2.get_children():
		if child is StaticBody3D:
			for shape_node in child.get_children():
				if shape_node is CollisionShape3D and shape_node.shape is BoxShape3D:
					found = shape_node.transform.origin.distance_to(aabb.get_center()) < 0.0001
	_record(found, "collision: preview carries box body centered on AABB")
	preview.free()
	preview2.free()


# ---------------------------------------------------------- 缺失依赖拒绝

func _check_missing_dependencies() -> void:
	var store := PCGStandardAssetStore.new()

	# 缺 Mesh。
	var no_mesh := _valid_asset("asset_no_mesh")
	no_mesh.normalized_mesh = null
	var refused: Dictionary = store.publish(no_mesh, _test_dir("missing_mesh"))
	_record(not refused["ok"] and _errors_contain(refused["errors"], "normalized_mesh")
		and not FileAccess.file_exists("user://pcg_standard_asset_test/missing_mesh/asset_no_mesh.asset.json"),
		"deps: publish without mesh refused before touching disk")

	# 缺验收报告。
	var no_report := _valid_asset("asset_no_report")
	no_report.acceptance_report = {}
	var refused2: Dictionary = store.publish(no_report, _test_dir("missing_report"))
	_record(not refused2["ok"] and _errors_contain(refused2["errors"], "acceptance_report"),
		"deps: publish without acceptance report refused")

	# 坏枚举字段。
	var bad_enum := _valid_asset("asset_bad_enum")
	bad_enum.uv_policy = &"stretch"
	bad_enum.category = &"portal"
	var refused3: Dictionary = store.publish(bad_enum, _test_dir("bad_enum"))
	_record(not refused3["ok"] and _errors_contain(refused3["errors"], "uv_policy")
		and _errors_contain(refused3["errors"], "category"),
		"deps: publish with unknown enums refused")

	# 坏 JSON / 未来版本 / 缺 payload。
	var dir := _test_dir("corrupt")
	var bad := FileAccess.open(dir + "/asset_bad.asset.json", FileAccess.WRITE)
	bad.store_string("{ not json")
	bad.close()
	var bad_load: Dictionary = store.load_asset(dir + "/asset_bad.asset.json")
	_record(not bad_load["ok"] and _errors_contain(bad_load["errors"], "invalid JSON"),
		"deps: corrupt JSON refused at reload")
	var newer := FileAccess.open(dir + "/asset_newer.asset.json", FileAccess.WRITE)
	newer.store_string('{"format_version": 99, "payload": {}}')
	newer.close()
	var newer_load: Dictionary = store.load_asset(dir + "/asset_newer.asset.json")
	_record(not newer_load["ok"] and _errors_contain(newer_load["errors"], "newer"),
		"deps: future format_version refused at reload")

	# 发布后删掉 lod1 网格文件 → 重载拒绝并点名缺失槽位。
	var dir2 := _test_dir("missing_lod_file")
	var asset := _valid_asset("asset_lose_lod")
	var published: Dictionary = store.publish(asset, dir2)
	_record(published["ok"], "deps: baseline publish for missing-file test")
	if published["ok"]:
		DirAccess.remove_absolute(ProjectSettings.globalize_path(dir2 + "/asset_lose_lod.lod1.mesh.res"))
		var lost: Dictionary = store.load_asset(published["path"])
		_record(not lost["ok"] and _errors_contain(lost["errors"], "missing mesh file")
			and _errors_contain(lost["errors"], "lod1"),
			"deps: reload with missing lod1 mesh file refused by name")

		# 删掉 JSON 引用的验收报告（手写剥离）→ 重载拒绝。
		var stripped := FileAccess.get_file_as_string(published["path"])
		var json := JSON.new()
		json.parse(stripped)
		var document: Dictionary = json.data
		document["payload"].erase("acceptance_report")
		var stripped_path := dir2 + "/asset_stripped.asset.json"
		var out := FileAccess.open(stripped_path, FileAccess.WRITE)
		out.store_string(JSON.stringify(document, "\t"))
		out.close()
		var stripped_load: Dictionary = store.load_asset(stripped_path)
		_record(not stripped_load["ok"] and _errors_contain(stripped_load["errors"], "acceptance_report"),
			"deps: reload without acceptance report refused")

	# 列表对坏文件给报告，不静默跳过。
	var list_dir := _test_dir("list_mixed")
	var good := _valid_asset("asset_list_good")
	var ok_publish: Dictionary = store.publish(good, list_dir)
	var broken := FileAccess.open(list_dir + "/asset_broken.asset.json", FileAccess.WRITE)
	broken.store_string('{"format_version": 1, "payload": {"stable_id": {"id": "bad id!"}}}')
	broken.close()
	if ok_publish["ok"]:
		var assets := store.list_assets(list_dir)
		_record(assets.size() == 1 and String(assets[0].asset_id()) == "asset_list_good",
			"deps: list keeps valid asset, skips broken", "count=%d" % assets.size())
		_record(String("; ".join(store.last_report)).contains("asset_broken"),
			"deps: list reports the broken file", String("; ".join(store.last_report)).substr(0, 80))

	# 原子中断：JSON 写入失败清理已写网格，不留半成品。
	var dir3 := _test_dir("atomic")
	var atomic_asset := _valid_asset("asset_atomic")
	var interrupted: Dictionary = store.publish(atomic_asset, dir3, "after_temp_write")
	_record(not interrupted["ok"], "atomic: injected JSON write interruption fails publish")
	var leftovers := false
	var access := DirAccess.open(dir3)
	for file_name in access.get_files():
		if String(file_name).begins_with("asset_atomic"):
			leftovers = true
	_record(not leftovers, "atomic: interrupted publish cleans all mesh files, no half product")
