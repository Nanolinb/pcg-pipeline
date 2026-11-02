class_name PCGMeshInspectorChecks
extends RefCounted

# v0.16 L1 几何验收与校准专项测试。
# 单源随共享包分发；mesh_inspector_check.gd（-s 入口）调用 run()。
# fixtures 来自 assets/raw/*.tres（由 scripts/tests/export_mesh_fixtures.gd
# 用 PCGMeshFixtureFactory 落盘），覆盖：有效/开放/退化/UV缺失/非流形体检、
# NaN 拒绝、任务预算（三角/材质/尺寸）核对、校准变换顺序、统一缩放、
# 顶点焊接、退化清理、开放保留与严重开放/非流形拒绝。

const LOG_PREFIX := "MESH"
const FIXTURE_DIR := "res://assets/raw"

var checks_run: int = 0
var failures: Array[String] = []
var _prefix: String = LOG_PREFIX
var _inspector: PCGAssetMeshInspector


func run(log_prefix: String = LOG_PREFIX) -> Dictionary:
	_prefix = log_prefix
	_inspector = PCGAssetMeshInspector.new()
	_check_null_mesh()
	_check_valid_crate()
	_check_open_crate()
	_check_degenerate_panels()
	_check_uv_missing_crate()
	_check_non_manifold_fan()
	_check_nan_mesh()
	_check_task_budgets()
	_check_calibrate_scale_and_weld()
	_check_calibrate_transform_order()
	_check_calibrate_degenerate_cleanup()
	_check_calibrate_open_boundary_preserved()
	_check_calibrate_refusals()
	return {"checks_run": checks_run, "failures": failures.duplicate()}


func _record(ok: bool, name: String, detail: String = "") -> void:
	checks_run += 1
	var label := name + ("" if detail.is_empty() else " (" + detail + ")")
	if ok:
		print("%s_CHECK_PASS: %s" % [_prefix, label])
	else:
		failures.append(label)
		print("%s_CHECK_FAIL: %s" % [_prefix, label])


func _fixture(name: String) -> ArrayMesh:
	var mesh: ArrayMesh = load("%s/%s.tres" % [FIXTURE_DIR, name])
	if mesh == null:
		_record(false, "fixture loads: %s" % name)
	return mesh


func _stats(result: Dictionary) -> Dictionary:
	return result["stats"]


func _errors_contain(errors: Array, needle: String) -> bool:
	for e in errors:
		if String(e).contains(needle):
			return true
	return false


func _actions_contain(actions: Array, needle: String) -> bool:
	for a in actions:
		if String(a).contains(needle):
			return true
	return false


# ------------------------------------------------------------------ 体检

func _check_null_mesh() -> void:
	var result := _inspector.inspect_mesh(null)
	_record(result["ok"] == false and _errors_contain(result["errors"], "null"),
		"inspect: null mesh rejected")


func _check_valid_crate() -> void:
	var result := _inspector.inspect_mesh(_fixture("valid_crate"))
	var stats := _stats(result)
	_record(result["ok"] == true, "inspect: valid crate passes", "; ".join(result["errors"]))
	_record(int(stats["triangles"]) == 12 and int(stats["surfaces"]) == 1,
		"inspect: valid crate has 12 triangles", "triangles=%d" % int(stats["triangles"]))
	_record(int(stats["boundary_edges"]) == 0 and int(stats["non_manifold_edges"]) == 0,
		"inspect: valid crate is closed and manifold",
		"boundary=%d non_manifold=%d" % [int(stats["boundary_edges"]), int(stats["non_manifold_edges"])])
	_record(bool(stats["uv0_present"]) and bool(stats["normals_present"]),
		"inspect: valid crate has UV0 and normals")
	_record((stats["aabb_size"] as Vector3).is_equal_approx(Vector3.ONE),
		"inspect: valid crate aabb is 1m cube", str(stats["aabb_size"]))


func _check_open_crate() -> void:
	var result := _inspector.inspect_mesh(_fixture("open_crate"))
	var stats := _stats(result)
	_record(result["ok"] == false and _errors_contain(result["errors"], "open"),
		"inspect: open crate rejected as open")
	_record(int(stats["boundary_edges"]) == 4 and int(stats["non_manifold_edges"]) == 0,
		"inspect: open crate exposes 4 boundary edges (missing top rim)",
		"boundary=%d" % int(stats["boundary_edges"]))


func _check_degenerate_panels() -> void:
	var result := _inspector.inspect_mesh(_fixture("degenerate_crate"))
	_record(result["ok"] == false and _errors_contain(result["errors"], "zero-area"),
		"inspect: degenerate crate rejected")
	_record(int(_stats(result)["degenerate_triangles"]) == 1
		and int(_stats(result)["triangles"]) == 13,
		"inspect: exactly one zero-area triangle among 13")


func _check_uv_missing_crate() -> void:
	var result := _inspector.inspect_mesh(_fixture("uv_missing_crate"))
	_record(result["ok"] == true, "inspect: uv-missing crate still passes with warnings")
	_record(not bool(_stats(result)["uv0_present"]),
		"inspect: uv0_present is false for uv-missing crate")
	var warned := false
	for warning in result["warnings"]:
		if String(warning).contains("UV0"):
			warned = true
	_record(warned, "inspect: missing UV0 reported as warning")


func _check_non_manifold_fan() -> void:
	var result := _inspector.inspect_mesh(_fixture("non_manifold_fan"))
	_record(result["ok"] == false and _errors_contain(result["errors"], "non-manifold"),
		"inspect: non-manifold fan rejected")
	_record(int(_stats(result)["non_manifold_edges"]) == 1,
		"inspect: exactly one non-manifold edge found")


func _check_nan_mesh() -> void:
	var result := _inspector.inspect_mesh(PCGMeshFixtureFactory.build_nan_mesh())
	_record(result["ok"] == false and _errors_contain(result["errors"], "NaN"),
		"inspect: NaN vertices rejected")


func _check_task_budgets() -> void:
	var task := PCGAssetTask.new()
	task.tri_budget = 6
	task.material_budget = 1
	task.size_max = Vector3(0.5, 0.5, 0.5)
	var result := _inspector.inspect_mesh(_fixture("valid_crate"), task)
	_record(_errors_contain(result["errors"], "exceed task budget"),
		"task: triangle budget exceeded reported")
	_record(_errors_contain(result["errors"], "exceeds size_max"),
		"task: size_over_max reported")
	var codes: Array = []
	for issue in result["issues"]:
		codes.append(String(issue["code"]))
	_record(codes.has("tri_budget_exceeded") and codes.has("size_over_max"),
		"task: issues carry machine-readable codes", ", ".join(codes))
	var tight := PCGAssetTask.new()
	tight.tri_budget = 13  # 12 三角，>90% 预算 → 警告而非错误
	var tight_result := _inspector.inspect_mesh(_fixture("valid_crate"), tight)
	var warned := false
	for warning in tight_result["warnings"]:
		if String(warning).contains("budget"):
			warned = true
	_record(tight_result["ok"] == true and warned,
		"task: near-budget usage warns without failing")


# ------------------------------------------------------------------ 校准

func _check_calibrate_scale_and_weld() -> void:
	var result := _inspector.calibrate_mesh(_fixture("valid_crate"),
		Vector3(2, 2, 2), Vector3.ZERO)
	_record(result["ok"] == true, "calibrate: valid crate calibrates cleanly",
		"; ".join(result["errors"]))
	_record(_actions_contain(result["actions"], "scaled_uniform:2.000000"),
		"calibrate: uniform scale action recorded", ", ".join(result["actions"]))
	_record(_actions_contain(result["actions"], "welded:16"),
		"calibrate: 24 duplicated corner verts welded to 8")
	var mesh: ArrayMesh = result["mesh"]
	_record(mesh != null and mesh.get_aabb().size.is_equal_approx(Vector3(2, 2, 2)),
		"calibrate: output aabb matches target size", str(mesh.get_aabb().size))
	_record(int(_stats(result)["triangles"]) == 12,
		"calibrate: triangle count preserved", "triangles=%d" % int(_stats(result)["triangles"]))


func _check_calibrate_transform_order() -> void:
	# beam_block 原始尺寸 1x2x4；先绕 Y 转 90°（x 与 z 互换），
	# 再按 target (2,2,2) 统一缩放 0.5，最后平移 root_offset (10,0,0)。
	var basis := Basis.from_euler(Vector3(0, PI / 2.0, 0))
	var result := _inspector.calibrate_mesh(_fixture("beam_block"),
		Vector3(2, 2, 2), Vector3(10, 0, 0), basis)
	_record(result["ok"] == true, "calibrate: rotated beam calibrates cleanly",
		"; ".join(result["errors"]))
	var mesh: ArrayMesh = result["mesh"]
	var aabb := mesh.get_aabb()
	_record(aabb.size.is_equal_approx(Vector3(2, 1, 0.5)),
		"calibrate: rotation then uniform scale normalizes dominant axis",
		"size=" + str(aabb.size))
	_record(aabb.position.is_equal_approx(Vector3(9, -0.5, -0.25)),
		"calibrate: root_offset applied in transformed space",
		"position=" + str(aabb.position))


func _check_calibrate_degenerate_cleanup() -> void:
	var result := _inspector.calibrate_mesh(_fixture("degenerate_crate"),
		Vector3.ZERO, Vector3.ZERO)
	_record(result["ok"] == true, "calibrate: degenerate crate cleaned",
		"; ".join(result["errors"]))
	_record(_actions_contain(result["actions"], "removed_degenerate:1"),
		"calibrate: degenerate removal recorded", ", ".join(result["actions"]))
	_record(int(_stats(result)["triangles"]) == 12,
		"calibrate: degenerate triangle dropped, closed cube of 12 remains")


func _check_calibrate_open_boundary_preserved() -> void:
	var result := _inspector.calibrate_mesh(_fixture("open_crate"), Vector3.ZERO, Vector3.ZERO)
	_record(result["ok"] == true,
		"calibrate: mildly open mesh calibrated without fake repair")
	_record(_actions_contain(result["actions"], "open_boundary_preserved:4"),
		"calibrate: preserved open boundary disclosed in actions", ", ".join(result["actions"]))
	_record(not _errors_contain(result["errors"], "mesh is open"),
		"calibrate: preserved open boundary not reported as residual error")
	_record(result["mesh"] != null, "calibrate: open crate still emits a mesh")


func _check_calibrate_refusals() -> void:
	var non_manifold := _inspector.calibrate_mesh(_fixture("non_manifold_fan"),
		Vector3.ONE, Vector3.ZERO)
	_record(non_manifold["ok"] == false and non_manifold["mesh"] == null
		and _errors_contain(non_manifold["errors"], "non-manifold"),
		"calibrate: non-manifold mesh refused, no pretend repair")
	var severe := _inspector.calibrate_mesh(PCGMeshFixtureFactory.build_single_triangle(),
		Vector3.ONE, Vector3.ZERO)
	_record(severe["ok"] == false and severe["mesh"] == null
		and _errors_contain(severe["errors"], "severely open"),
		"calibrate: 100% open mesh refused, no pretend repair")
	var nan := _inspector.calibrate_mesh(PCGMeshFixtureFactory.build_nan_mesh(),
		Vector3.ONE, Vector3.ZERO)
	_record(nan["ok"] == false and nan["mesh"] == null
		and _errors_contain(nan["errors"], "NaN"),
		"calibrate: NaN mesh refused")
	var zero_tolerance := _inspector.calibrate_mesh(_fixture("valid_crate"),
		Vector3.ONE, Vector3.ZERO, Basis.IDENTITY, 0.0)
	_record(zero_tolerance["ok"] == false
		and _errors_contain(zero_tolerance["errors"], "weld_tolerance"),
		"calibrate: non-positive weld tolerance rejected")
