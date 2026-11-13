extends RefCounted

# v0.14 表面宿主专项测试 runner（docs/core_contracts.md §4 / 验收 T5）。
# 由 scripts/tests/run_surface_host_test.gd（-s 启动脚本）在运行期 load() 后
# 调用 run(tree)；保持 runner 与启动入口分离，启动脚本保持极小。
# 覆盖：
# 1. PCGSurfaceHostData（纯数据宿主）满足宿主契约，无需任何 CSG/节点类型；
# 2. PCGFusedWall 节点适配器暴露同一契约（薄包装，语义不变）；
# 3. 纯数据宿主与既有 fused_wall 数学逐项等价（surface_transform /
#    surface_distance / clamp_anchor / 射线锚点），G0 行为不变；
# 4. PCGSurfaceMath 纯函数内核的已知值锚定（平面/圆柱/半球圆柱的
#    transform/distance/clamp/raycast），以及与节点适配器的逐项等价
#    （适配器 = 内核 + 坐标系适配）；
# 5. 非法输入与非宿主对象返回明确失败，测试以非零退出码报告。
#
# 注意：禁止静态引用任何全局类（PCGFusedWall / PCGComponentDefinition /
# PCGSurfaceHost*），一律在运行期 load()，否则脚本会在 autoload 注册前
# 被编译，依赖脚本因找不到 autoload 标识符而编译失败。

const KIND_PLANE := 0
const KIND_CYLINDER := 1
const KIND_DOME_CYLINDER := 2
const KIND_NAMES := {0: "plane", 1: "cylinder", 2: "dome_cylinder"}

var checks_run: int = 0
var failures: Array[String] = []
var _surface_host_script: GDScript = null
var _surface_host_data_script: GDScript = null
var _fused_script: GDScript = null
var _definition_script: GDScript = null
var _math_script: GDScript = null

var _tree: SceneTree = null

func run(tree: SceneTree) -> void:
	_tree = tree
	print("HOST_TEST_BEGIN: surface host contract check")
	if not _load_scripts():
		return
	_check_enum_stability()
	_check_pure_data_contract()
	_check_pure_data_math()
	_check_adapter_contract()
	await _check_adapter_parity()
	_check_kernel_math()
	await _check_kernel_parity()
	_check_negative_paths()

func _load_scripts() -> bool:
	_surface_host_script = _load_global_class("PCGSurfaceHost")
	_surface_host_data_script = _load_global_class("PCGSurfaceHostData")
	_fused_script = load("res://scripts/fused_wall.gd")
	_definition_script = load("res://scripts/component_definition.gd")
	_math_script = load("res://addons/pcg_shared/pcg_surface_math.gd")
	var ok := _surface_host_script != null and _surface_host_data_script != null \
		and _fused_script != null and _definition_script != null and _math_script != null
	_record(ok, "scripts compile", "host=%s data=%s fused=%s definition=%s math=%s" % [
		_surface_host_script != null, _surface_host_data_script != null,
		_fused_script != null, _definition_script != null, _math_script != null])
	return ok

func _record(ok: bool, name: String, detail: String = "") -> void:
	checks_run += 1
	if ok:
		print("HOST_TEST_PASS: %s%s" % [name, "" if detail.is_empty() else " (" + detail + ")"])
	else:
		failures.append(name + ("" if detail.is_empty() else " (" + detail + ")"))
		print("HOST_TEST_FAIL: %s%s" % [name, "" if detail.is_empty() else " (" + detail + ")"])

func _load_global_class(class_id: String) -> GDScript:
	for entry in ProjectSettings.get_global_class_list():
		if String(entry.get("class", "")) == class_id:
			_record(true, "global class registered: " + class_id)
			return load(String(entry["path"]))
	_record(false, "global class registered: " + class_id)
	return null

func _validate(candidate: Object) -> Array:
	return _surface_host_script.validate_surface_host(candidate)

func _check_enum_stability() -> void:
	# 枚举值只允许追加，不得改变既有含义（契约 §4）。
	var host_kinds: Dictionary = _surface_host_script.get_script_constant_map()["SurfaceKind"]
	_record(int(host_kinds["PLANE"]) == KIND_PLANE
		and int(host_kinds["CYLINDER"]) == KIND_CYLINDER
		and int(host_kinds["DOME_CYLINDER"]) == KIND_DOME_CYLINDER,
		"surface kind enum values stable")
	var fused_kinds: Dictionary = _fused_script.get_script_constant_map()["SurfaceKind"]
	_record(int(fused_kinds["PLANE"]) == int(host_kinds["PLANE"])
		and int(fused_kinds["CYLINDER"]) == int(host_kinds["CYLINDER"])
		and int(fused_kinds["DOME_CYLINDER"]) == int(host_kinds["DOME_CYLINDER"]),
		"fused wall kind enum matches contract enum")

func _new_host_data(kind: int):
	var host = _surface_host_data_script.new()
	host.host_id = &"test_host"
	host.surface_kind = kind
	return host

func _check_pure_data_contract() -> void:
	# 纯数据宿主：不持有任何 Node/CSG 引用，满足全部契约成员。
	for kind in [KIND_PLANE, KIND_CYLINDER, KIND_DOME_CYLINDER]:
		var host = _new_host_data(kind)
		_record(_validate(host).is_empty(),
			"pure data host satisfies contract", "kind=%d" % kind)
		var path_data: Dictionary = host.host_path_data()
		_record(path_data.has("host_id") and path_data.has("surface_kind")
			and path_data.has("coordinate") and path_data.has("paths")
			and path_data["paths"] is Array, "host_path_data structure stable", "kind=%d" % kind)
		_record(host.occupancy_query({}) is Array, "occupancy_query returns Array", "kind=%d" % kind)
		var frame: Dictionary = host.surface_frame(Vector2(0.3, -0.2))
		_record(frame.has("position") and frame.has("normal") and frame.has("tangent")
			and frame.has("bitangent"), "surface_frame structure stable", "kind=%d" % kind)
		var tangent: Vector3 = frame["tangent"]
		var normal: Vector3 = frame["normal"]
		_record(is_equal_approx(tangent.dot(normal), 0.0), "surface_frame axes orthogonal", "kind=%d" % kind)

func _check_pure_data_math() -> void:
	# 已知值数学检查（不依赖 fused_wall，独立锚定纯数据宿主语义）。
	var plane = _new_host_data(KIND_PLANE)
	var plane_transform: Transform3D = plane.surface_transform(Vector2(1.5, -2.0))
	_record(plane_transform.origin.is_equal_approx(Vector3(1.5, -2.0, plane.thickness * 0.5)),
		"plane anchor maps to surface point", "origin=%s" % plane_transform.origin)
	_record(plane.surface_distance(Vector2(0.0, 0.0), Vector2(3.0, 4.0)) == 5.0,
		"plane distance is euclidean")
	var cylinder = _new_host_data(KIND_CYLINDER)
	# 圆柱 wrap：弧长差取短弧。
	var circumference: float = TAU * cylinder.cylinder_radius
	var long_arc: float = circumference * 0.75
	_record(is_equal_approx(cylinder.surface_distance(Vector2(0.0, 0.0), Vector2(long_arc, 0.0)),
		circumference * 0.25), "cylinder distance wraps around circumference")
	var radial: Transform3D = cylinder.surface_transform(Vector2(0.0, 0.0))
	_record(radial.origin.is_equal_approx(Vector3(0.0, 0.0, cylinder.cylinder_radius)),
		"cylinder anchor unwraps to radial point")
	# 射线：从圆柱外侧沿径向射入必须命中原点锚点。
	var hit: Dictionary = cylinder.surface_raycast(Vector3(0.0, 0.7, cylinder.cylinder_radius + 2.0),
		Vector3(0.0, 0.0, -1.0))
	_record(not hit.is_empty() and (hit["anchor"] as Vector2).is_equal_approx(Vector2(0.0, 0.7)),
		"cylinder radial raycast hits anchor", "anchor=%s" % hit.get("anchor", Vector2.ZERO))
	# 半球圆柱：越过赤道高度的锚点落在穹顶上，法线带 y 分量。
	var dome = _new_host_data(KIND_DOME_CYLINDER)
	var equator: float = dome.cylinder_height * 0.5
	var dome_transform: Transform3D = dome.surface_transform(Vector2(0.0, equator + 0.3))
	var dome_normal: Vector3 = dome_transform.basis.z
	_record(dome_normal.y > 0.0, "dome anchor normal tilts upward", "normal=%s" % dome_normal)
	var side_transform: Transform3D = dome.surface_transform(Vector2(0.0, equator - 0.3))
	_record(is_equal_approx(side_transform.basis.z.y, 0.0), "cylinder band anchor normal stays horizontal")
	# 注册/注销语义。
	dome.register_component(&"win_a", Vector2(0.1, 0.2))
	dome.register_component(&"win_a", Vector2(0.3, 0.4))
	dome.register_component(&"win_b", Vector2(-0.5, 0.0))
	_record(dome.component_order == [&"win_a", &"win_b"]
		and (dome.component_anchors[&"win_a"] as Vector2).is_equal_approx(Vector2(0.3, 0.4)),
		"register_component deduplicates and updates anchor")
	dome.unregister_component(&"win_a")
	_record(dome.component_order == [&"win_b"] and not dome.component_anchors.has(&"win_a"),
		"unregister_component removes anchor and order")
	# 锚点回绕：clamp 把越界弧长折回 ±half_arc。
	var clamped: Vector2 = dome.clamp_anchor(Vector2(50.0, 0.0), Vector2(0.8, 0.8))
	_record(absf(clamped.x) <= PI * dome.cylinder_radius + 0.001,
		"clamp_anchor wraps arc coordinate", "x=%f" % clamped.x)

func _check_adapter_contract() -> void:
	# 节点适配器（不加入场景树即可做方法面检查）。
	var host = _fused_script.new()
	_record(_validate(host).is_empty(), "fused wall adapter satisfies contract")
	_record(int(host.surface_kind) == KIND_PLANE,
		"fused wall default kind matches contract PLANE")
	host.free()

func _make_fused(kind: int):
	var host = _fused_script.new()
	host.surface_kind = kind
	host.wall_size = Vector3(6.0, 4.6, 0.36)
	host.cylinder_radius = 1.35
	host.cylinder_height = 3.8
	host.cylinder_depth = 0.7
	host.position = Vector3(0.4, -0.3, 1.2)
	host.rotation = Vector3(0.1, 0.6, -0.2)
	_tree.root.add_child(host)
	return host

func _check_adapter_parity() -> void:
	# G0 等价性：适配器与纯数据宿主在相同参数、相同世界位姿下逐项一致。
	var anchors := [Vector2(0.0, 0.0), Vector2(0.6, -1.1), Vector2(-1.7, 2.2), Vector2(2.9, 0.4)]
	for kind in [KIND_PLANE, KIND_CYLINDER, KIND_DOME_CYLINDER]:
		var fused = _make_fused(kind)
		await _tree.process_frame
		var data = _new_host_data(kind)
		data.host_transform = fused.global_transform
		for anchor in anchors:
			var from_fused: Transform3D = fused.surface_transform(anchor)
			var from_data: Transform3D = data.surface_transform(anchor)
			_record(from_fused.is_equal_approx(from_data),
				"surface_transform parity (%s)" % KIND_NAMES[kind], "anchor=%s" % anchor)
		# 既有 ray_anchor 语义不变：surface_raycast 薄包装必须逐键一致。
		var ray_origin: Vector3 = fused.global_transform * Vector3(0.3, 0.5, 6.0)
		var ray_direction: Vector3 = (fused.global_transform.basis.z * -1.0).normalized()
		var legacy: Dictionary = fused.ray_anchor(ray_origin, ray_direction)
		var contract: Dictionary = fused.surface_raycast(ray_origin, ray_direction)
		_record(legacy.size() == contract.size()
			and (legacy.is_empty() or (
				(legacy["anchor"] as Vector2).is_equal_approx(contract["anchor"])
				and (legacy["position"] as Vector3).is_equal_approx(contract["position"])
				and (legacy["normal"] as Vector3).is_equal_approx(contract["normal"])
				and legacy["host"] == contract["host"])),
			"surface_raycast matches ray_anchor (%s)" % KIND_NAMES[kind])
		# 纯数据宿主在适配器世界位姿下的射线等价（host 键指向各自对象，跳过）。
		if not legacy.is_empty():
			var data_hit: Dictionary = data.surface_raycast(ray_origin, ray_direction)
			_record(not data_hit.is_empty()
				and (data_hit["anchor"] as Vector2).is_equal_approx(legacy["anchor"])
				and (data_hit["position"] as Vector3).is_equal_approx(legacy["position"])
				and (data_hit["normal"] as Vector3).is_equal_approx(legacy["normal"]),
				"pure data raycast parity (%s)" % KIND_NAMES[kind])
		# 距离等价。
		for a in anchors:
			for b in anchors:
				_record(is_equal_approx(fused.surface_distance(a, b), data.surface_distance(a, b)),
					"surface_distance parity (%s)" % KIND_NAMES[kind], "a=%s b=%s" % [a, b])
		# 锚点钳制等价（含越界/回绕输入）。
		var definition = _definition_script.new()
		definition.size = Vector2(1.2, 0.9)
		for anchor in anchors + [Vector2(40.0, 8.0), Vector2(-40.0, -8.0)]:
			_record((fused.clamp_anchor(anchor, definition) as Vector2).is_equal_approx(
				data.clamp_anchor(anchor, definition.size)),
				"clamp_anchor parity (%s)" % KIND_NAMES[kind], "anchor=%s" % anchor)
		# surface_frame 与 surface_transform 一致。
		var frame: Dictionary = fused.surface_frame(anchors[1])
		var via_transform: Transform3D = fused.surface_transform(anchors[1])
		_record((frame["position"] as Vector3).is_equal_approx(via_transform.origin)
			and (frame["normal"] as Vector3).is_equal_approx(via_transform.basis.z.normalized())
			and frame["host"] == fused,
			"surface_frame consistent with surface_transform (%s)" % KIND_NAMES[kind])
		var path_data: Dictionary = fused.host_path_data()
		_record(path_data.has("host_id") and path_data.has("surface_kind")
			and int(path_data["surface_kind"]) == kind and (path_data["paths"] as Array).is_empty(),
			"adapter host_path_data structure stable (%s)" % KIND_NAMES[kind])
		_record((fused.occupancy_query({}) as Array).is_empty(),
			"adapter occupancy_query stable empty (%s)" % KIND_NAMES[kind])
		fused.queue_free()
		await _tree.process_frame

func _check_kernel_math() -> void:
	# 内核已知值锚定：不依赖任何宿主，独立锁定纯函数语义。
	var wall := Vector3(6.0, 4.6, 0.36)
	var radius := 1.35
	var height := 3.8
	var depth := 0.7
	var identity := Transform3D.IDENTITY
	# 平面：锚点映射到墙面点，距离为欧氏，钳制到墙面内缩边界。
	var plane_t: Transform3D = _math_script.surface_transform(KIND_PLANE,
		Vector2(1.5, -2.0), identity, wall, radius, height, wall.z)
	_record(plane_t.origin.is_equal_approx(Vector3(1.5, -2.0, wall.z * 0.5)),
		"kernel plane transform maps anchor to surface point")
	_record(_math_script.surface_distance(KIND_PLANE, Vector2.ZERO, Vector2(3.0, 4.0), radius) == 5.0,
		"kernel plane distance is euclidean")
	var plane_c: Vector2 = _math_script.clamp_anchor(KIND_PLANE,
		Vector2(99.0, -99.0), Vector2(1.2, 0.9), wall, radius, height)
	_record(plane_c.is_equal_approx(Vector2(2.35, -1.8)),
		"kernel plane clamp hits inset limits", "clamped=%s" % plane_c)
	var plane_hit: Dictionary = _math_script.raycast(KIND_PLANE,
		Vector3(0.3, 0.5, 6.0), Vector3(0.0, 0.0, -1.0), identity, wall, radius, height, wall.z)
	_record(not plane_hit.is_empty()
		and (plane_hit["anchor"] as Vector2).is_equal_approx(Vector2(0.3, 0.5))
		and not plane_hit.has("host"),
		"kernel plane raycast hits and stays host-free", "hit=%s" % plane_hit)
	_record((_math_script.raycast(KIND_PLANE, Vector3(0.0, 0.0, 6.0),
		Vector3(0.0, 0.0, 1.0), identity, wall, radius, height, wall.z) as Dictionary).is_empty(),
		"kernel plane raycast miss returns empty")
	_record((_math_script.raycast(KIND_PLANE, Vector3(10.0, 0.0, 6.0),
		Vector3(0.0, 0.0, -1.0), identity, wall, radius, height, wall.z) as Dictionary).is_empty(),
		"kernel plane raycast outside wall returns empty")
	# 圆柱：距离沿周长取短弧，锚点展开到径向点，射线命中径向锚点。
	var circumference := TAU * radius
	_record(is_equal_approx(_math_script.surface_distance(KIND_CYLINDER,
		Vector2.ZERO, Vector2(circumference * 0.75, 0.0), radius), circumference * 0.25),
		"kernel cylinder distance wraps around circumference")
	var cyl_t: Transform3D = _math_script.surface_transform(KIND_CYLINDER,
		Vector2.ZERO, identity, wall, radius, height, depth)
	_record(cyl_t.origin.is_equal_approx(Vector3(0.0, 0.0, radius)),
		"kernel cylinder transform unwraps to radial point")
	var cyl_hit: Dictionary = _math_script.raycast(KIND_CYLINDER,
		Vector3(0.0, 0.7, radius + 2.0), Vector3(0.0, 0.0, -1.0), identity, wall, radius, height, depth)
	_record(not cyl_hit.is_empty() and (cyl_hit["anchor"] as Vector2).is_equal_approx(Vector2(0.0, 0.7)),
		"kernel cylinder radial raycast hits anchor", "anchor=%s" % cyl_hit.get("anchor", Vector2.ZERO))
	var cyl_c: Vector2 = _math_script.clamp_anchor(KIND_CYLINDER,
		Vector2(50.0, 0.0), Vector2(0.8, 0.8), wall, radius, height)
	_record(absf(cyl_c.x) <= PI * radius + 0.001,
		"kernel cylinder clamp wraps arc coordinate", "x=%f" % cyl_c.x)
	# 半球圆柱：越过赤道的锚点法线上倾，穹顶射线命中极点锚点，钳制上界含穹顶弧长。
	var equator := height * 0.5
	var dome_t: Transform3D = _math_script.surface_transform(KIND_DOME_CYLINDER,
		Vector2(0.0, equator + 0.3), identity, wall, radius, height, depth)
	_record(dome_t.basis.z.y > 0.0, "kernel dome transform normal tilts upward")
	var dome_hit: Dictionary = _math_script.raycast(KIND_DOME_CYLINDER,
		Vector3(0.0, equator + radius + 2.0, 0.0), Vector3(0.0, -1.0, 0.0), identity, wall, radius, height, depth)
	_record(not dome_hit.is_empty()
		and (dome_hit["anchor"] as Vector2).is_equal_approx(Vector2(0.0, equator + radius * PI * 0.5)),
		"kernel dome raycast hits pole anchor", "anchor=%s" % dome_hit.get("anchor", Vector2.ZERO))
	var dome_c: Vector2 = _math_script.clamp_anchor(KIND_DOME_CYLINDER,
		Vector2(0.0, 99.0), Vector2(0.8, 0.8), wall, radius, height)
	_record(is_equal_approx(dome_c.y, equator + radius * PI * 0.5 - 0.05),
		"kernel dome clamp reaches dome top", "y=%f" % dome_c.y)

func _check_kernel_parity() -> void:
	# 内核 ↔ 节点适配器逐项等价：适配器只允许做坐标系适配（传 global_transform）
	# 与补 "host" 键，数学必须来自内核。G0 行为不变的直接证据。
	var anchors := [Vector2(0.0, 0.0), Vector2(0.6, -1.1), Vector2(-1.7, 2.2), Vector2(2.9, 0.4)]
	var definition = _definition_script.new()
	definition.size = Vector2(1.2, 0.9)
	for kind in [KIND_PLANE, KIND_CYLINDER, KIND_DOME_CYLINDER]:
		var fused = _make_fused(kind)
		await _tree.process_frame
		for anchor in anchors:
			var via_kernel: Transform3D = _math_script.surface_transform(kind, anchor,
				fused.global_transform, fused.wall_size, fused.cylinder_radius,
				fused.cylinder_height, fused.thickness)
			_record(via_kernel.is_equal_approx(fused.surface_transform(anchor)),
				"kernel transform parity (%s)" % KIND_NAMES[kind], "anchor=%s" % anchor)
		for a in anchors:
			for b in anchors:
				_record(is_equal_approx(
					_math_script.surface_distance(kind, a, b, fused.cylinder_radius),
					fused.surface_distance(a, b)),
					"kernel distance parity (%s)" % KIND_NAMES[kind], "a=%s b=%s" % [a, b])
		for anchor in anchors + [Vector2(40.0, 8.0), Vector2(-40.0, -8.0)]:
			_record((_math_script.clamp_anchor(kind, anchor, definition.size,
				fused.wall_size, fused.cylinder_radius, fused.cylinder_height) as Vector2).is_equal_approx(
				fused.clamp_anchor(anchor, definition)),
				"kernel clamp parity (%s)" % KIND_NAMES[kind], "anchor=%s" % anchor)
		var ray_origin: Vector3 = fused.global_transform * Vector3(0.3, 0.5, 6.0)
		var ray_direction: Vector3 = (fused.global_transform.basis.z * -1.0).normalized()
		var kernel_hit: Dictionary = _math_script.raycast(kind, ray_origin, ray_direction,
			fused.global_transform, fused.wall_size, fused.cylinder_radius,
			fused.cylinder_height, fused.thickness)
		var adapter_hit: Dictionary = fused.ray_anchor(ray_origin, ray_direction)
		_record(kernel_hit.is_empty() == adapter_hit.is_empty()
			and (kernel_hit.is_empty() or (
				(kernel_hit["anchor"] as Vector2).is_equal_approx(adapter_hit["anchor"])
				and (kernel_hit["position"] as Vector3).is_equal_approx(adapter_hit["position"])
				and (kernel_hit["normal"] as Vector3).is_equal_approx(adapter_hit["normal"])
				and not kernel_hit.has("host"))),
			"kernel raycast parity (%s)" % KIND_NAMES[kind])
		fused.queue_free()
		await _tree.process_frame

func _check_negative_paths() -> void:
	# 非宿主对象必须被校验器完整列出缺失成员（8 个契约方法）。
	var bogus := RefCounted.new()
	var problems: Array = _validate(bogus)
	_record(problems.size() == 8, "validator lists all missing members", "count=%d" % problems.size())
	# 空组件 ID 注册必须被拒绝且不产生状态。
	var host = _new_host_data(KIND_PLANE)
	host.register_component(&"", Vector2.ZERO)
	_record(host.component_anchors.is_empty(), "empty component_id rejected")
	# 空 ID 宿主的基类虚拟方法返回安全默认值并上报错误。
	var base = _surface_host_script.new()
	_record((base.surface_transform(Vector2.ZERO) as Transform3D).is_equal_approx(Transform3D.IDENTITY),
		"base surface_transform fails safe to identity")
	_record((base.surface_raycast(Vector3.ZERO, Vector3.FORWARD) as Dictionary).is_empty(),
		"base surface_raycast fails safe to empty")
	# 未命中射线返回空字典，不生成半份结果。
	_record((host.surface_raycast(Vector3(0.0, 0.0, 6.0), Vector3(0.0, 0.0, 1.0)) as Dictionary).is_empty(),
		"missed ray returns empty dictionary")
