extends SceneTree

var failures := PackedStringArray()
var checks := 0

const PANEL_KINDS := [&"solid", &"window", &"door", &"passage", &"corner"]

func _initialize() -> void:
	call_deferred("_run")

func _run() -> void:
	var catalog := PCGBuildingComponentCatalog.new()
	catalog.load_from("res://assets/building_components")
	_check(catalog.errors.is_empty(), "六份标准组件应无加载错误")

	# 契约默认值与语义数据
	var demo := PCGBuildingPlan.demo()
	var house_l: PCGBuildingFootprint = demo.get_footprint(&"house_l")
	_check(demo.validation_errors().is_empty(), "演示平面应通过校验")
	_check(house_l.get("wall_panels_fused") == true,
		"footprint 默认应 fused 显示（wall_panels_fused 缺失或默认非 true）")
	_check(is_equal_approx(float(house_l.get("wall_panel_width")), 1.75),
		"footprint 默认墙板模数应为 1.75（wall_panel_width 缺失或非 1.75）")
	var semantic: Dictionary = house_l.semantic_data()
	_check(semantic.has("wall_panel_width") and semantic.has("wall_panels_fused"),
		"semantic_data 必须包含墙板模数与显示开关")
	var has_contract: bool = semantic.has("wall_panel_width") and semantic.has("wall_panels_fused")
	if has_contract:
		_check(is_equal_approx(float(semantic["wall_panel_width"]), 1.75),
			"semantic_data 应记录默认模数 1.75")

	# 默认 fused：旧行为完全保留
	var generator := PCGBuildingGenerator.new()
	var fused_result := generator.build_plan(demo, catalog)
	_check(fused_result["errors"].is_empty(), "默认 fused 平面应成功生成")
	_check(fused_result["buildings"].size() == 3, "演示应生成三栋建筑")
	var digest: String = fused_result["stats"]["digest"]
	var fused_again := generator.build_plan(PCGBuildingPlan.demo(), catalog)
	_check(fused_again["errors"].is_empty() and fused_again["stats"]["digest"] == digest,
		"默认 fused 生成必须保持确定性")
	for building in fused_result["buildings"]:
		var body := building.get_node_or_null("DerivedSolid") as MeshInstance3D
		_check(body != null and body.mesh != null,
			"fused 默认必须继续生成 DerivedSolid 完整网格：%s" % building.name)
		_check(_panel_instances(building).is_empty(),
			"fused 默认不得出现单元墙板显示：%s" % building.name)

	# 单元模式：独立生成路径（无 connector）
	if has_contract:
		var unit_fp := PCGBuildingPlan.demo().get_footprint(&"house_l")
		unit_fp.set("wall_panels_fused", false)
		var unit_build := generator.build_building(unit_fp, PCGBuildingPlan.demo().master_seed, catalog)
		_check(unit_build["errors"].is_empty(), "单元模式应成功生成")
		var unit_root: Node3D = unit_build["root"]
		if _require(unit_root != null, "单元模式应返回建筑根节点"):
			var unit_panels := _panel_instances(unit_root)
			_check(not unit_panels.is_empty(), "单元模式必须生成 WallPanels 墙板实例")
			_check(_panel_kinds(unit_panels).has_all([&"solid", &"window", &"door", &"corner"]),
				"单元模式必须覆盖 solid/window/door/corner 类型：%s" % str(_panel_kinds(unit_panels)))
			_check(_slot_ids_valid(unit_panels, &"house_l"),
				"slot_id 必须符合 wall:{building}:e{edge}:f{floor}:p{panel} / wall:{building}:v{vertex}:f{floor} 格式")
			_check(_panel_meshes_valid(unit_panels), "每个墙板必须是含顶点/法线/索引且无 NaN 的有效网格")
			_check(_panel_normals_match(unit_panels, unit_fp.normalized_polygon()),
				"分板墙面的法线方向必须与融合墙面及组件局部 +Z 约定一致")
			_check(_combined_bounds_covers(unit_root, unit_fp),
				"单元模式仍需屋顶与地面封闭整体外观（整体包围盒应覆盖全高）")

			# fused 与单元模式的组件本体必须同源（StandardComponents 不复制、不改随机流）
			var fused_build := generator.build_building(PCGBuildingPlan.demo().get_footprint(&"house_l"),
				PCGBuildingPlan.demo().master_seed, catalog)
			_check(_component_signature(fused_build["root"]) == _component_signature(unit_root),
				"门窗本体必须继续只由 StandardComponents 生成，fused/单元模式组件排布一致")

			# 相同输入布局确定
			var repeat_fp := PCGBuildingPlan.demo().get_footprint(&"house_l")
			repeat_fp.set("wall_panels_fused", false)
			var repeat_build := generator.build_building(repeat_fp, PCGBuildingPlan.demo().master_seed, catalog)
			_check(_panel_signature(_panel_instances(repeat_build["root"])) == _panel_signature(unit_panels),
				"相同输入的派生墙板布局必须逐 slot 确定")

			# 模数变化只影响派生单元，不改平面/组件/连接器
			var wide_fp := PCGBuildingPlan.demo().get_footprint(&"house_l")
			wide_fp.set("wall_panels_fused", false)
			wide_fp.set("wall_panel_width", 2.5)
			_check(wide_fp.validation_errors().is_empty(), "合法模数 2.5 应通过校验")
			var wide_build := generator.build_building(wide_fp, PCGBuildingPlan.demo().master_seed, catalog)
			_check(wide_build["errors"].is_empty(), "模数 2.5 单元模式应成功生成")
			_check(_panel_signature(_panel_instances(wide_build["root"])) != _panel_signature(unit_panels),
				"模数变化必须改变派生墙板布局")
			var core_before := _semantic_core(PCGBuildingPlan.demo().get_footprint(&"house_l"))
			_check(_semantic_core(wide_fp) == core_before,
				"模数变化不得改变平面/楼层/种子/组件等核心语义")
			_check(_component_signature(wide_build["root"]) == _component_signature(unit_root),
				"模数变化不得改变 StandardComponents 组件排布")

			# connector 实际开口对应 passage 单元
			var connected_plan := PCGBuildingPlan.demo()
			var connector := PCGSkybridgeConnector.new()
			connector.id = &"wall_panel_probe"
			connector.building_id = &"house_l"
			connector.edge_index = 1
			connector.floor = 1
			connected_plan.connectors.append(connector)
			var connected_fp: PCGBuildingFootprint = connected_plan.get_footprint(&"house_l")
			connected_fp.set("wall_panels_fused", false)
			var connected_build := generator.build_building(connected_fp, connected_plan.master_seed, catalog,
				connected_plan.footprints, connected_plan.facade_exclusions_for(&"house_l"),
				connected_plan, connected_plan.connectors_for_building(&"house_l"))
			_check(connected_build["errors"].is_empty(), "带 connector 的单元模式应成功生成")
			_check(_panel_kinds(_panel_instances(connected_build["root"])).has(&"passage"),
				"connector 实际开口必须产生 passage 墙板单元")
			connected_build["root"].free()
			wide_build["root"].free()
			repeat_build["root"].free()
			fused_build["root"].free()
			unit_root.free()
	fused_result["root"].free()
	fused_again["root"].free()

	# 非法模数：校验错误而非坏网格
	var bad_fp := PCGBuildingPlan.demo().get_footprint(&"house_l")
	bad_fp.set("wall_panel_width", 0.0)
	var bad_errors := bad_fp.validation_errors()
	_check(not bad_errors.is_empty(), "非法模数 0.0 必须产生校验错误")
	var bad_build := generator.build_building(bad_fp, PCGBuildingPlan.demo().master_seed, catalog)
	_check(bad_build["root"] == null and not bad_build["errors"].is_empty(),
		"非法模数必须拒绝生成且不留坏网格")
	var bad_plan := PCGBuildingPlan.demo()
	bad_plan.get_footprint(&"house_l").set("wall_panel_width", -1.0)
	_check(not bad_plan.validation_errors().is_empty(), "平面校验必须传播非法模数错误")
	bad_plan.get_footprint(&"house_l").set("wall_panel_width", 4.5)
	_check(not bad_plan.validation_errors().is_empty(), "超过 4.0 m 的模数必须被统一校验拒绝")

	# 工作台集成：切换、撤销/重做、单栋隔离
	await _run_workbench_checks()

	await process_frame
	if failures.is_empty():
		print("WALL_PANEL_TEST_RESULT: PASS checks=%d" % checks)
		quit(0)
	else:
		for failure in failures:
			push_error("WALL_PANEL_TEST: " + failure)
		print("WALL_PANEL_TEST_RESULT: FAIL checks=%d failures=%d" % [checks, failures.size()])
		quit(1)

func _run_workbench_checks() -> void:
	var scene: PackedScene = load("res://scenes/building_workbench.tscn")
	var workbench := scene.instantiate()
	root.add_child(workbench)
	await process_frame
	await physics_frame
	_check(workbench.building_nodes.size() == 3, "工作台应显示三栋可编辑建筑")
	for building in workbench.building_nodes.values():
		_check(building.get_node_or_null("DerivedSolid") != null and _panel_instances(building).is_empty(),
			"工作台默认必须为 fused 显示：%s" % building.name)

	var house_l: PCGBuildingFootprint = workbench.plan.get_footprint(&"house_l")
	var core_semantics := _semantic_core(house_l)
	var untouched: Node3D = workbench.building_nodes[&"house_tower"]
	var house_node_before: Node3D = workbench.building_nodes[&"house_l"]

	workbench._select_footprint(&"house_l")
	workbench.undo_redo.clear_history()
	_check(workbench.has_method("_on_panel_preview_toggled"),
		"工作台必须提供 _on_panel_preview_toggled 以切换单元显示")
	if workbench.has_method("_on_panel_preview_toggled"):
		workbench._on_panel_preview_toggled(true)
		var unit_node: Node3D = workbench.building_nodes[&"house_l"]
		_check(unit_node != house_node_before, "切换显示必须重建选中建筑")
		_check(unit_node.get_node_or_null("WallPanels") != null and not _panel_instances(unit_node).is_empty(),
			"单元模式应以 WallPanels 显示选中建筑")
		_check(not _panel_instances(unit_node).is_empty()
			and _slot_ids_valid(_panel_instances(unit_node), &"house_l"),
			"工作台单元模式墙板必须带稳定 slot_id")
		_check(workbench.building_nodes[&"house_tower"] == untouched,
			"单栋切换不得重建其他建筑")
		_check(_semantic_core(house_l) == core_semantics,
			"fused 切换不得改变 footprint 核心语义（平面/楼层/种子/组件）")
		workbench.undo_redo.undo()
		_check(house_l.get("wall_panels_fused") == true
			and _panel_instances(workbench.building_nodes[&"house_l"]).is_empty()
			and workbench.building_nodes[&"house_l"].get_node_or_null("DerivedSolid") != null,
			"撤销必须经 workbench 历史恢复 fused 显示状态")
		_check(workbench.building_nodes[&"house_tower"] == untouched,
			"撤销切换不得重建其他建筑")
		workbench.undo_redo.redo()
		_check(house_l.get("wall_panels_fused") == false
			and not _panel_instances(workbench.building_nodes[&"house_l"]).is_empty(),
			"重做必须恢复单元显示状态")
		workbench.undo_redo.undo()
		_check(house_l.get("wall_panels_fused") == true,
			"再次撤销应回到 fused 默认值")

	_check(workbench.has_method("_on_wall_panel_width_changed"),
		"工作台必须提供 _on_wall_panel_width_changed 以调整墙板模数")
	if workbench.has_method("_on_wall_panel_width_changed"):
		workbench._select_footprint(&"house_l")
		workbench.undo_redo.clear_history()
		workbench._on_wall_panel_width_changed(2.5)
		_check(is_equal_approx(float(house_l.get("wall_panel_width")), 2.5),
			"模数修改应写入选中 footprint")
		_check(workbench.building_nodes[&"house_tower"] == untouched,
			"模数修改只应重建选中建筑")
		workbench.undo_redo.undo()
		_check(is_equal_approx(float(house_l.get("wall_panel_width")), 1.75),
			"撤销应恢复默认模数 1.75")
		workbench.undo_redo.redo()
		_check(is_equal_approx(float(house_l.get("wall_panel_width")), 2.5),
			"重做应恢复新模数")
		workbench.undo_redo.undo()
	workbench.queue_free()
	await process_frame

func _panel_instances(building: Node) -> Array:
	var panels: Array = []
	var holder := building.get_node_or_null("WallPanels")
	if holder == null:
		return panels
	_collect_panels(holder, panels)
	return panels

func _collect_panels(node: Node, out: Array) -> void:
	for child in node.get_children():
		if child is MeshInstance3D:
			out.append(child)
		else:
			_collect_panels(child, out)

func _panel_kinds(panels: Array) -> Dictionary:
	var kinds := {}
	for panel in panels:
		kinds[panel.get_meta("panel_kind", &"")] = true
	return kinds

func _panel_signature(panels: Array) -> Array:
	var entries: Array[String] = []
	for panel in panels:
		entries.append("%s|%s|%d" % [
			String(panel.get_meta("slot_id", &"")),
			String(panel.get_meta("panel_kind", &"")),
			_mesh_triangles(panel.mesh),
		])
	entries.sort()
	return entries

func _slot_ids_valid(panels: Array, building_id: StringName) -> bool:
	var seen := {}
	var edge_slot := RegEx.new()
	edge_slot.compile("^wall:%s:e[0-9]+:f[0-9]+:p[0-9]+$" % building_id)
	var corner_slot := RegEx.new()
	corner_slot.compile("^wall:%s:v[0-9]+:f[0-9]+$" % building_id)
	for panel in panels:
		var slot := String(panel.get_meta("slot_id", &""))
		if edge_slot.search(slot) == null and corner_slot.search(slot) == null:
			return false
		if seen.has(slot):
			return false
		seen[slot] = true
		if not PANEL_KINDS.has(panel.get_meta("panel_kind", &"")):
			return false
	return true

func _panel_meshes_valid(panels: Array) -> bool:
	for panel in panels:
		var mesh: Mesh = panel.mesh
		if mesh == null or mesh.get_surface_count() == 0:
			return false
		for surface in mesh.get_surface_count():
			var arrays := mesh.surface_get_arrays(surface)
			var vertices: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
			var normals: PackedVector3Array = arrays[Mesh.ARRAY_NORMAL]
			var indices: PackedInt32Array = arrays[Mesh.ARRAY_INDEX]
			if vertices.is_empty() or normals.size() != vertices.size() or indices.is_empty():
				return false
			for vertex in vertices:
				if not is_finite(vertex.x) or not is_finite(vertex.y) or not is_finite(vertex.z):
					return false
	return true

func _panel_normals_match(panels: Array, polygon: PackedVector2Array) -> bool:
	for panel in panels:
		var edge_index := int(panel.get_meta("edge_index", -1))
		if edge_index < 0:
			continue
		var arrays: Array = panel.mesh.surface_get_arrays(0)
		var normals: PackedVector3Array = arrays[Mesh.ARRAY_NORMAL]
		if normals.is_empty():
			return false
		var edge: Vector2 = polygon[(edge_index + 1) % polygon.size()] - polygon[edge_index]
		var expected := Vector3(edge.y, 0.0, -edge.x).normalized()
		var actual: Vector3 = (panel.transform.basis * normals[0]).normalized()
		if actual.distance_to(expected) > 0.0001:
			return false
	return true

func _combined_bounds_covers(building: Node, footprint: PCGBuildingFootprint) -> bool:
	var min_y := INF
	var max_y := -INF
	for node in building.find_children("*", "MeshInstance3D", true, false):
		var mi := node as MeshInstance3D
		if mi.mesh == null:
			continue
		var local: AABB = mi.get_aabb()
		for corner in [local.position, local.position + Vector3(local.size.x, 0, 0),
				local.position + Vector3(0, local.size.y, 0), local.position + Vector3(0, 0, local.size.z),
				local.position + Vector3(local.size.x, local.size.y, 0),
				local.position + Vector3(local.size.x, 0, local.size.z),
				local.position + Vector3(0, local.size.y, local.size.z), local.end]:
			var world: Vector3 = _relative_transform(building, mi) * corner
			min_y = minf(min_y, world.y)
			max_y = maxf(max_y, world.y)
	return min_y <= building.position.y + 0.05 and max_y >= building.position.y + footprint.height() - 0.05

func _relative_transform(building: Node3D, node: Node3D) -> Transform3D:
	var relative := node.transform
	var current := node.get_parent()
	while current != null and current != building:
		relative = (current as Node3D).transform * relative
		current = current.get_parent()
	return building.transform * relative

func _component_signature(building: Node) -> Array:
	var entries: Array[String] = []
	var components := building.get_node("StandardComponents")
	for child in components.get_children():
		var origin: Vector3 = child.transform.origin
		entries.append("%s|%s|%.4f|%.4f|%.4f" % [
			String(child.get_meta("component_id", &"")),
			str(int(child.get_meta("component_role", -1))),
			origin.x, origin.y, origin.z,
		])
	entries.sort()
	return entries

func _semantic_core(footprint: PCGBuildingFootprint) -> Dictionary:
	var data := footprint.semantic_data()
	data.erase("wall_panel_width")
	data.erase("wall_panels_fused")
	return data

func _mesh_triangles(mesh: Mesh) -> int:
	var count := 0
	for surface in mesh.get_surface_count():
		var indices = mesh.surface_get_arrays(surface)[Mesh.ARRAY_INDEX]
		count += int(indices.size() / 3) if indices != null else 0
	return count

func _require(condition: bool, message: String) -> bool:
	_check(condition, message)
	return condition

func _check(condition: bool, message: String) -> void:
	checks += 1
	if not condition:
		failures.append(message)
