extends SceneTree

const Connector = preload("res://scripts/building/skybridge_connector.gd")
const Bridge = preload("res://scripts/building/skybridge_definition.gd")

var failures := PackedStringArray()
var checks := 0

func _initialize() -> void:
	call_deferred("_run")

func _run() -> void:
	var catalog := PCGBuildingComponentCatalog.new()
	catalog.load_from("res://assets/building_components")
	_check(catalog.errors.is_empty(), "标准组件目录应无加载错误：%s" % "; ".join(catalog.errors))
	var generator := PCGSkybridgeGenerator.new()
	_test_connector_and_bridge_creation(generator, catalog)
	_test_window_avoidance(catalog)
	_test_node_editing()
	_test_cross_merge_and_lift(generator, catalog)
	_test_sloped_bridge(generator, catalog)
	_test_determinism(generator, catalog)
	await _test_workbench_integration()
	_finish()

func _test_connector_and_bridge_creation(generator: PCGSkybridgeGenerator, catalog: PCGBuildingComponentCatalog) -> void:
	var plan := PCGBuildingPlan.demo()
	var bad := Connector.new()
	bad.id = &"conn_bad"
	bad.building_id = &"house_l"
	bad.edge_index = 1
	bad.edge_t = 0.5
	bad.floor = 99
	_check(not bad.validation_errors(plan.get_footprint(&"house_l")).is_empty(),
		"超出建筑层数的结合点必须被拒绝")
	var first := _connector(&"conn_a", &"house_l", 1, 0.5, 1)
	var second := _connector(&"conn_b", &"house_tower", 3, 0.5, 1)
	plan.connectors.append(first)
	plan.connectors.append(second)
	_check(catalog.get_definition(&"skybridge_basic") != null, "廊桥标准组件应已注册进目录")
	_check(catalog.get_definition(&"skybridge_basic").role == PCGBuildingComponentDefinition.Role.SKYBRIDGE,
		"skybridge_basic 的角色应为 SKYBRIDGE")
	var component_mesh := catalog.get_definition(&"skybridge_basic").get_mesh()
	_check(component_mesh.get_surface_count() == 2, "廊桥组件应提供结构与围栏两个材质槽")
	var empty_bridge := Bridge.new()
	empty_bridge.id = &"bridge_empty"
	empty_bridge.connector_a = &"conn_a"
	empty_bridge.connector_b = &"conn_b"
	_check(not empty_bridge.validation_errors().is_empty(), "空节点廊桥应被校验拒绝")
	var made := generator.make_bridge(plan, first, second, &"bridge_x", catalog)
	_check(made["errors"].is_empty(), "两个合法结合点应能生成廊桥：%s" % "; ".join(made["errors"]))
	var bridge: PCGSkybridgeDefinition = made["bridge"]
	_check(bridge != null and bridge.nodes.size() == 3, "默认廊桥应包含起终与中间三个节点")
	_check(is_equal_approx(bridge.width, 2.0) and is_equal_approx(bridge.height, 3.0),
		"廊桥截面尺寸应取自标准组件")
	var result := generator.build_network(plan, catalog)
	_check(result["errors"].is_empty(), "廊桥网络应成功生成：%s" % "; ".join(result["errors"]))
	_check(result["root"] != null, "廊桥网络应产生显示根节点")
	_check(result["junctions"].is_empty(), "单条无交叉廊桥不应产生合并结构")
	var inspector := PCGAssetMeshInspector.new()
	var bridge_visual: MeshInstance3D = result["root"].get_child(0)
	var inspection := inspector.inspect_mesh(bridge_visual.mesh)
	_check(inspection["ok"], "廊桥扫掠网格应封闭且无退化面：%s" % inspection["errors"])
	_check(inspection["stats"]["uv0_present"] and inspection["stats"]["normals_present"],
		"廊桥网格应具备 UV0 和法线")
	_check(bridge_visual.mesh.get_surface_count() == 2, "廊桥网格应包含结构与围栏两个表面")
	result["root"].free()

func _test_window_avoidance(catalog: PCGBuildingComponentCatalog) -> void:
	var plain := PCGBuildingGenerator.new().build_building(
		PCGBuildingPlan.demo().get_footprint(&"house_l"), "seed", catalog)
	_check(plain["errors"].is_empty(), "无避让参数的建筑应正常生成")
	var footprint := PCGBuildingPlan.demo().get_footprint(&"house_l")
	var connector := _connector(&"conn_a", &"house_l", 1, 0.5, 1)
	var avoided := PCGBuildingGenerator.new().build_building(
		footprint, "seed", catalog, [], [connector.exclusion(footprint)])
	_check(avoided["errors"].is_empty(), "带避让参数的建筑应正常生成")
	var plain_count := _edge_floor_windows(plain["root"], 1, 1)
	var avoided_count := _edge_floor_windows(avoided["root"], 1, 1)
	_check(plain_count > 0, "无避让时结合点所在边与楼层应有窗口")
	_check(avoided_count == 0, "结合点所在开间的窗口应被完全避让，实测 %d" % avoided_count)
	_check(_total_windows(avoided["root"]) < _total_windows(plain["root"]),
		"避让后总窗口数应减少并重新排布")
	plain["root"].free()
	avoided["root"].free()

func _test_node_editing() -> void:
	var bridge := PCGSkybridgeDefinition.new()
	bridge.id = &"bridge_edit"
	bridge.connector_a = &"a"
	bridge.connector_b = &"b"
	bridge.nodes = [
		{"position": Vector3(0, 2.6, 0), "tension": 1.0},
		{"position": Vector3(4, 2.6, 0), "tension": 1.0},
		{"position": Vector3(8, 2.6, 0), "tension": 1.0},
	]
	var straight := bridge.sampled_path(8)
	_check(straight.size() == 17, "三次 Hermite 采样点数应为 跨度×8+1")
	var max_dev := 0.0
	for point in straight:
		max_dev = maxf(max_dev, absf(point.y - 2.6))
	_check(max_dev < 0.001, "共线节点自然采样应保持在桥面高度")
	bridge.nodes[1]["position"] = Vector3(4, 4.6, 2.0)
	var arced := bridge.sampled_path(8)
	var arced_dev := 0.0
	for point in arced:
		arced_dev = maxf(arced_dev, absf(point.z))
	_check(arced_dev > 0.5, "移动中间节点应改变路径走向")
	bridge.set_node_tension(1, 0.0)
	var eased := bridge.sampled_path(8)
	_check(not eased[4].is_equal_approx(arced[4]), "转弯强度变化应改变弧度过渡")
	bridge.auto_lift = 1.5
	_check(is_equal_approx(bridge.node_positions()[0].y, 4.1), "自动错开抬升应叠加到节点高度")
	_check(bridge.semantic_data()["nodes"].size() == 3, "语义数据应包含全部节点")

func _test_sloped_bridge(generator: PCGSkybridgeGenerator, catalog: PCGBuildingComponentCatalog) -> void:
	var plan := PCGBuildingPlan.demo()
	var low := _connector(&"conn_low", &"house_l", 1, 0.3, 1)
	var high := _connector(&"conn_tower", &"house_tower", 3, 0.3, 3)
	plan.connectors.append(low)
	plan.connectors.append(high)
	var bridge: PCGSkybridgeDefinition = generator.make_bridge(plan, low, high, &"bridge_slope", catalog)["bridge"]
	plan.skybridges.append(bridge)
	var rise := bridge.node_positions()[2].y - bridge.node_positions()[0].y
	_check(rise > 4.0, "不同楼层的结合点应产生桥面高差，实测 %0.2f" % rise)
	var result := generator.build_network(plan, catalog)
	_check(result["errors"].is_empty(), "坡道廊桥应成功生成：%s" % "; ".join(result["errors"]))
	var visual: MeshInstance3D = result["root"].get_child(0)
	var inspector := PCGAssetMeshInspector.new()
	var inspection := inspector.inspect_mesh(visual.mesh)
	_check(inspection["ok"], "坡道廊桥网格应封闭且无退化面：%s" % inspection["errors"])
	var deck_min := INF
	var deck_max := -INF
	for point in bridge.sampled_path(8):
		deck_min = minf(deck_min, point.y)
		deck_max = maxf(deck_max, point.y)
	_check(deck_max - deck_min > 4.0, "坡道桥面应沿路径连续爬升")
	result["root"].free()

func _test_cross_merge_and_lift(generator: PCGSkybridgeGenerator, catalog: PCGBuildingComponentCatalog) -> void:
	var merged_plan := _crossing_plan(catalog)
	generator.build_network(merged_plan)
	_check(merged_plan.get_skybridge(&"bridge_1") != null
		and merged_plan.get_skybridge(&"bridge_2") != null, "交叉测试计划应包含两条廊桥")
	var first := generator.build_network(merged_plan, catalog)
	_check(first["errors"].is_empty(), "同层交叉廊桥应成功生成：%s" % "; ".join(first["errors"]))
	_check(first["junctions"].size() == 1, "横截面完全重叠的交叉应合并为一个 cross 结构")
	var junction_boxes := 0
	for child in first["root"].get_children():
		if child.get_meta("bridge_role", "") == "skybridge_junction":
			junction_boxes += 1
	_check(junction_boxes == 2, "cross 结构应由两个方向的交汇盒组成")
	first["root"].free()

	var lifted_plan := _crossing_plan(catalog)
	for node in lifted_plan.get_skybridge(&"bridge_2").nodes:
		var position: Vector3 = node["position"]
		position.y = 4.0
		node["position"] = position
	var second := generator.build_network(lifted_plan, catalog)
	_check(second["junctions"].is_empty(), "垂直重叠不足 60% 的交叉不应合并")
	var lift := lifted_plan.get_skybridge(&"bridge_2").auto_lift
	_check(lift > 2.1 and lift < 2.3, "较低廊桥应自动错开到净空上方，实测 %+0.2f" % lift)
	var deck_after := INF
	for point in lifted_plan.get_skybridge(&"bridge_2").sampled_path(8):
		deck_after = minf(deck_after, point.y)
	_check(deck_after >= 5.6 - 0.001, "错开后桥面应位于下层桥顶之上")
	second["root"].free()

	var boundary_plan := _crossing_plan(catalog)
	for node in boundary_plan.get_skybridge(&"bridge_2").nodes:
		var position: Vector3 = node["position"]
		position.y = 3.5
		node["position"] = position
	var third := generator.build_network(boundary_plan, catalog)
	_check(third["junctions"].size() == 1, "重叠 70%（超过 60%）的交叉仍应合并")
	third["root"].free()

func _test_determinism(generator: PCGSkybridgeGenerator, catalog: PCGBuildingComponentCatalog) -> void:
	var plan := PCGBuildingPlan.demo()
	var first := _connector(&"conn_a", &"house_l", 1, 0.5, 1)
	var second := _connector(&"conn_b", &"house_tower", 3, 0.5, 1)
	plan.connectors.append(first)
	plan.connectors.append(second)
	plan.skybridges.append(generator.make_bridge(plan, first, second, &"bridge_x", catalog)["bridge"])
	var one := generator.build_network(plan)
	var two := generator.build_network(plan)
	_check(one["errors"].is_empty() and two["errors"].is_empty(), "确定性测试网络应生成成功")
	_check(one["root"].get_meta("semantic_digest") == two["root"].get_meta("semantic_digest"),
		"同输入的廊桥网络语义摘要必须一致")
	one["root"].free()
	two["root"].free()

func _test_workbench_integration() -> void:
	var scene: PackedScene = load("res://scenes/building_workbench.tscn")
	var workbench = scene.instantiate()
	root.add_child(workbench)
	await process_frame
	await physics_frame
	_check(workbench.plan.connectors.size() == 2, "工作台演示应包含两个结合点")
	_check(workbench.plan.skybridges.size() == 1, "工作台演示应包含一条示例廊桥")
	_check(workbench.skybridge_root != null, "工作台应已生成廊桥显示")
	var bridge_nodes := 0
	for child in workbench.skybridge_root.get_children():
		if child.get_meta("bridge_role", "") == "skybridge":
			bridge_nodes += 1
	_check(bridge_nodes == 1, "演示应渲染一条廊桥")
	var inspector := PCGAssetMeshInspector.new()
	for child in workbench.skybridge_root.get_children():
		var inspection := inspector.inspect_mesh(child.mesh)
		_check(inspection["ok"], "廊桥网格应封闭且无退化面：%s / %s" % [child.name, inspection["errors"]])
	workbench._on_connector_placed(&"house_l", 4, 0.5)
	workbench._on_connector_placed(&"house_tower", 1, 0.5)
	_check(workbench.plan.connectors.size() == 4, "标注结合点应加入平面数据")
	workbench._create_skybridge()
	_check(workbench.plan.skybridges.size() == 2, "生成廊桥应连接两个空闲结合点")
	workbench.undo_redo.undo()
	_check(workbench.plan.skybridges.size() == 1, "撤销应移除新生成的廊桥")
	_check(workbench.plan.connectors.size() == 4, "撤销廊桥不应影响结合点")
	workbench.undo_redo.redo()
	_check(workbench.plan.skybridges.size() == 2, "重做应恢复廊桥")
	var bridge = workbench.plan.get_skybridge(&"bridge_2")
	bridge.set_node_tension(1, 0.0)
	bridge.set_node_position(1, Vector3(1.8, 3.4, -1.0))
	workbench._sync_skybridges()
	_check(workbench.skybridge_root != null, "节点编辑后廊桥网络应重建")
	workbench.undo_redo.undo()
	workbench.undo_redo.undo()
	_check(workbench.plan.get_skybridge(&"bridge_2") == null, "连续撤销应回到标注前状态")
	workbench.undo_redo.clear_history()
	workbench.queue_free()
	await process_frame

func _connector(id: StringName, building: StringName, edge: int, t: float, floor: int) -> PCGSkybridgeConnector:
	var connector := Connector.new()
	connector.id = id
	connector.building_id = building
	connector.edge_index = edge
	connector.edge_t = t
	connector.floor = floor
	return connector

# 两栋相对建筑 + 两条在中段交叉的廊桥。
func _crossing_plan(catalog: PCGBuildingComponentCatalog) -> PCGBuildingPlan:
	var plan := PCGBuildingPlan.new()
	var west := PCGBuildingFootprint.new()
	west.id = &"west"
	west.polygon = PackedVector2Array([
		Vector2(0, 0), Vector2(4, 0), Vector2(4, 4), Vector2(0, 4)])
	west.floors = 3
	var east := PCGBuildingFootprint.new()
	east.id = &"east"
	east.polygon = PackedVector2Array([
		Vector2(10, 0), Vector2(14, 0), Vector2(14, 4), Vector2(10, 4)])
	east.floors = 3
	plan.footprints.append(west)
	plan.footprints.append(east)
	var connectors := [
		_connector(&"c1", &"west", 1, 0.2, 1),
		_connector(&"c2", &"east", 3, 0.2, 1),
		_connector(&"c3", &"west", 1, 0.8, 1),
		_connector(&"c4", &"east", 3, 0.8, 1),
	]
	for connector in connectors:
		plan.connectors.append(connector)
	var generator := PCGSkybridgeGenerator.new()
	plan.skybridges.append(generator.make_bridge(plan, connectors[0], connectors[1], &"bridge_1", catalog)["bridge"])
	plan.skybridges.append(generator.make_bridge(plan, connectors[2], connectors[3], &"bridge_2", catalog)["bridge"])
	return plan

func _edge_floor_windows(building: Node3D, edge_index: int, floor: int) -> int:
	var count := 0
	var components: Node3D = building.get_node("StandardComponents")
	for child in components.get_children():
		if int(child.get_meta("component_role", -1)) != PCGBuildingComponentDefinition.Role.WINDOW:
			continue
		var origin: Vector3 = child.transform.origin
		if absf(origin.x - 0.225) > 0.05:
			continue
		var floor_base := float(floor) * 2.6
		if origin.y > floor_base + 0.5 and origin.y < floor_base + 2.6:
			count += 1
	return count

func _total_windows(building: Node3D) -> int:
	var count := 0
	var components: Node3D = building.get_node("StandardComponents")
	for child in components.get_children():
		if int(child.get_meta("component_role", -1)) == PCGBuildingComponentDefinition.Role.WINDOW:
			count += 1
	return count

func _finish() -> void:
	if failures.is_empty():
		print("SKYBRIDGE_TEST_RESULT: PASS checks=%d" % checks)
		quit(0)
	else:
		for failure in failures:
			push_error("SKYBRIDGE_TEST: " + failure)
		print("SKYBRIDGE_TEST_RESULT: FAIL checks=%d failures=%d" % [checks, failures.size()])
		quit(1)

func _check(condition: bool, message: String) -> void:
	checks += 1
	if not condition:
		failures.append(message)
