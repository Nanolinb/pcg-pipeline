extends SceneTree

var failures := PackedStringArray()
var checks := 0

func _initialize() -> void:
	call_deferred("_run")

func _run() -> void:
	var catalog := PCGBuildingComponentCatalog.new()
	catalog.load_from("res://assets/building_components")
	_check(catalog.errors.is_empty(), "六份标准组件应无加载错误")
	_check(catalog.definitions.size() == 12, "应加载十二份标准组件")
	var inspector := PCGAssetMeshInspector.new()
	for definition in catalog.definitions:
		var inspection := inspector.inspect_mesh(definition.get_mesh())
		_check(inspection["ok"], "组件 Mesh 应封闭且无退化面：%s / %s" % [definition.id, inspection["errors"]])
		_check(inspection["stats"]["uv0_present"] and inspection["stats"]["normals_present"], "组件应具备 UV0 和法线：%s" % definition.id)
	var plan := PCGBuildingPlan.demo()
	_check(plan.validation_errors().is_empty(), "演示平面应通过校验")
	var generator := PCGBuildingGenerator.new()
	var result := generator.build_plan(plan, catalog)
	_check(result["errors"].is_empty(), "完整平面应成功生成")
	_check(result["buildings"].size() == 3, "演示应生成三栋建筑")
	_check(result["stats"]["components"] > 40, "立面与屋顶应实际实例化标准组件")
	_check(result["stats"]["triangles"] > 1000, "输出应包含实际三角网格")
	var digest: String = result["stats"]["digest"]
	var second := generator.build_plan(plan, catalog)
	_check(second["stats"]["digest"] == digest, "同输入的语义摘要必须一致")
	_check(second["stats"]["components"] == result["stats"]["components"], "同输入的组件数量必须一致")
	_check(second["stats"]["triangles"] == result["stats"]["triangles"], "同输入的三角统计必须一致")
	for building in result["buildings"]:
		var body := building.get_node("DerivedSolid") as MeshInstance3D
		var inspection := inspector.inspect_mesh(body.mesh)
		_check(inspection["ok"], "挤出主体必须封闭且无退化面：%s / %s" % [building.name, inspection["errors"]])
		_check(_signed_volume(body.mesh) < 0.0, "主体应使用 Godot 朝外绕序：%s" % building.name)
	var connector := PCGSkybridgeConnector.new()
	connector.id = &"wall_probe"
	connector.building_id = &"house_l"
	connector.edge_index = 1
	connector.floor = 1
	plan.connectors.append(connector)
	var opened := generator.build_building(plan.get_footprint(&"house_l"), plan.master_seed, catalog,
		plan.footprints, plan.facade_exclusions_for(&"house_l"), plan, plan.connectors_for_building(&"house_l"))
	var opened_body := opened["root"].get_node_or_null("DerivedSolid") as MeshInstance3D
	_check(opened_body != null and opened_body.mesh != null and inspector.inspect_mesh(opened_body.mesh)["ok"], "带廊桥门洞时主体墙面必须生成且保持封闭")
	opened["root"].free()
	plan.connectors.clear()
	var role_counts := _role_counts(result["root"])
	_check(role_counts.get(DefinitionRole("DOOR"), 0) == 2, "两栋建筑应保留单门入口")
	_check(role_counts.get(DefinitionRole("DOUBLE_DOOR"), 0) == 1, "主建筑应使用带遮阳顶的双门入口")
	_check(role_counts.get(DefinitionRole("WINDOW"), 0) > 20, "立面应生成窗户阵列")
	_check(role_counts.get(DefinitionRole("PARAPET"), 0) == 14, "女儿墙应覆盖全部轮廓边")
	_check(role_counts.get(DefinitionRole("ROOF_HATCH"), 0) == 3, "每栋建筑应有屋顶组件")
	_check(role_counts.get(DefinitionRole("ROOF_DRYING_RACK"), 0) == 1, "只有同时容纳检修屋和晾衣架的屋顶才生成晾衣架")
	_check(role_counts.get(DefinitionRole("BALCONY"), 0) >= 3, "每栋建筑应至少有一个小阳台")
	var component_ids := _meta_counts(result["root"], "component_id")
	_check(component_ids.get(&"window_drying_rod_basic", 0) > 0, "立面应包含空晾衣杆")
	_check(component_ids.get(&"window_drying_clothes_basic", 0) > 0, "立面应包含带衣服的晾衣杆")
	_check(_decoration_overlap_count(result["root"], generator, catalog) == 0, "门、窗、阳台和立面装饰不得互相重叠")
	_check(_decorations_have_valid_hosts(result["root"]), "装饰必须依附于实际通过检查的宿主窗户")
	var corner_polygon := plan.get_footprint(&"house_l").normalized_polygon()
	_check(not generator._corner_clearance(corner_polygon, 2, 0.02, catalog.get_definition(&"window_basic")), "凹角附近的窗户必须被净空规则拒绝")
	_check(not _entrances_hit_other_buildings(result["root"], plan, generator, catalog), "入口及遮阳顶不得插入其他建筑")
	_check(_roof_racks_fit(result["root"], plan, generator, catalog), "晾衣架完整占地不得穿出女儿墙或碰到检修屋")
	var tiny := PCGBuildingFootprint.new()
	tiny.id = &"tiny_roof"
	tiny.polygon = PackedVector2Array([Vector2(-0.55, -0.55), Vector2(0.55, -0.55), Vector2(0.55, 0.55), Vector2(-0.55, 0.55)])
	var tiny_result := generator.build_building(tiny, plan.master_seed, catalog)
	_check(_role_counts(tiny_result["root"]).get(DefinitionRole("ROOF_DRYING_RACK"), 0) == 0, "明显过小的屋顶不得生成晾衣架")
	tiny_result["root"].free()
	plan.get_footprint(&"house_l").window_component_id = &"missing_window"
	var invalid := generator.build_plan(plan, catalog)
	_check(invalid["root"] == null and not invalid["errors"].is_empty(), "缺失组件必须拒绝生成且不留半份结果")
	plan.get_footprint(&"house_l").window_component_id = &"window_basic"
	plan.get_footprint(&"house_l").polygon = PackedVector2Array([
		Vector2.ZERO, Vector2(2.0, 2.0), Vector2(0.0, 2.0), Vector2(2.0, 0.0),
	])
	_check(not plan.validation_errors().is_empty(), "自交平面必须被校验拦截")
	plan = PCGBuildingPlan.demo()

	# 完整生成必须与增量路径同源：结合点避让与门洞裁切在 build_plan 中同样生效。
	var connected := PCGBuildingPlan.demo()
	var plan_connector := PCGSkybridgeConnector.new()
	plan_connector.id = &"conn_plan"
	plan_connector.building_id = &"house_l"
	plan_connector.edge_index = 1
	plan_connector.edge_t = 0.5
	plan_connector.floor = 1
	connected.connectors.append(plan_connector)
	var connected_result := generator.build_plan(connected, catalog)
	_check(connected_result["errors"].is_empty(), "带结合点的平面应通过完整生成")
	var connected_l: Node3D = null
	for building in connected_result["buildings"]:
		if building.get_meta("footprint_id") == &"house_l":
			connected_l = building
	_check(connected_l != null and _edge_floor_windows(connected_l, 1, 1) == 0,
		"完整生成必须与增量路径一样避让结合点开间")
	var plain_l := generator.build_building(PCGBuildingPlan.demo().get_footprint(&"house_l"), "seed", catalog)
	var plain_triangles := _mesh_triangles(plain_l["root"].get_node("DerivedSolid").mesh)
	var cut_triangles := _mesh_triangles(connected_l.get_node("DerivedSolid").mesh)
	_check(cut_triangles > plain_triangles, "完整生成必须在结合点处裁切门洞（内凹洞道）")
	plain_l["root"].free()
	var plan_doorway_frames := 0
	for child in connected_l.get_node("StandardComponents").get_children():
		var frame_role: int = int(child.get_meta("component_role", -1))
		if frame_role == DefinitionRole("DOOR") or frame_role == DefinitionRole("DOUBLE_DOOR"):
			plan_doorway_frames += 1
	_check(plan_doorway_frames == 1, "完整生成下建筑侧只保留自身入口，门套由廊桥侧生成")
	connected_result["root"].free()

	# 基准标高不得从一次构建泄漏到后续调用。
	var sloped := PCGBuildingPlan.demo()
	sloped.terrain_slope = Vector2(0.14, 0.08)
	var sloped_result := generator.build_plan(sloped, catalog)
	_check(sloped_result["errors"].is_empty(), "斜坡平面应成功生成")
	var probe := generator._component_bounds(catalog.get_definition(&"window_basic"),
		Transform3D(Basis.IDENTITY, Vector3.ZERO), Vector3.ONE)
	var probe_local := catalog.get_definition(&"window_basic").get_mesh().get_aabb().position.y
	_check(is_equal_approx(probe.position.y, probe_local),
		"构建结束后基准标高不得泄漏到后续 _component_bounds 调用")
	sloped_result["root"].free()

	# 入口 bay 与窗口排布同源：未遮挡时门落在统一推导的开间中心。
	var door_def: PCGBuildingComponentDefinition = catalog.get_definition(&"double_door_canopy_basic")
	var window_def: PCGBuildingComponentDefinition = catalog.get_definition(&"window_basic")
	var entrance_polygon := PCGBuildingPlan.demo().get_footprint(&"house_l").normalized_polygon()
	var entrance_info := generator._choose_entrance(entrance_polygon, door_def, window_def, &"house_l", [], 0.0)
	var plain_build := generator.build_building(PCGBuildingPlan.demo().get_footprint(&"house_l"), "seed", catalog)
	var entrance_door: MeshInstance3D = null
	for child in plain_build["root"].get_node("StandardComponents").get_children():
		if int(child.get_meta("component_role", -1)) == DefinitionRole("DOUBLE_DOOR"):
			entrance_door = child
	var entrance_edge: int = entrance_info["edge"]
	var ea: Vector2 = entrance_polygon[entrance_edge]
	var eb: Vector2 = entrance_polygon[(entrance_edge + 1) % entrance_polygon.size()]
	var door_origin: Vector3 = entrance_door.transform.origin
	var door_t := (Vector2(door_origin.x, door_origin.z) - ea).dot(eb - ea) / (eb - ea).length_squared()
	var entrance_spacing := maxf(window_def.size.x * 1.75, 1.25)
	var entrance_bays := int(floor((eb - ea).length() / entrance_spacing))
	var expected_t := (float(entrance_info["bay"]) + 0.5) / float(entrance_bays)
	_check(entrance_door != null and absf(door_t - expected_t) < 0.02,
		"入口门必须落在与窗口同一套推导的开间中心")
	plain_build["root"].free()

	# 入口边被结合点遮挡时，门改放到重排后的真实开间（旧实现因间距公式不一致会丢门）。
	var blocked_fp := PCGBuildingPlan.demo().get_footprint(&"house_l")
	var blocked_conn := PCGSkybridgeConnector.new()
	blocked_conn.id = &"conn_block"
	blocked_conn.building_id = &"house_l"
	blocked_conn.edge_index = entrance_edge
	blocked_conn.edge_t = 0.2
	blocked_conn.floor = 0
	var blocked_result := generator.build_building(blocked_fp, "seed", catalog, [],
		[blocked_conn.exclusion(blocked_fp)], null, [blocked_conn])
	var blocked_doors := 0
	for child in blocked_result["root"].get_node("StandardComponents").get_children():
		if int(child.get_meta("component_role", -1)) == DefinitionRole("DOUBLE_DOOR"):
			blocked_doors += 1
	_check(blocked_result["errors"].is_empty() and blocked_doors == 1,
		"入口边被结合点遮挡时，入口门仍应落在重排后的真实开间（门套由廊桥侧生成）")
	blocked_result["root"].free()

	var scene: PackedScene = load("res://scenes/building_workbench.tscn")
	var workbench := scene.instantiate()
	root.add_child(workbench)
	await process_frame
	await physics_frame
	_check(workbench.building_nodes.size() == 3, "工作台应显示三栋可编辑建筑")
	_check(workbench.catalog.definitions.size() == 12, "工作台应显示完整标准组件库")
	var untouched: Node3D = workbench.building_nodes[&"house_tower"]
	var selected: PCGBuildingFootprint = workbench.plan.get_footprint(&"house_l")
	selected.polygon[0] += Vector2(-0.5, 0.0)
	workbench._rebuild_building(selected.id)
	_check(workbench.building_nodes[&"house_tower"] == untouched, "编辑建筑 A 不得重建建筑 B")
	_check(workbench.building_nodes[&"house_l"] != null, "编辑后应存在新的建筑显示")
	workbench._select_footprint(&"house_l")
	var before_repair: Node3D = workbench.building_nodes[&"house_l"]
	workbench._repair_selected()
	_check(workbench.building_nodes[&"house_l"] != before_repair and workbench.building_nodes[&"house_tower"] == untouched, "一键修复只应重建选中建筑")
	_check(String(workbench.status_label.text).contains("已修复选中建筑"), "一键修复应给出明确结果反馈")
	var before_seed: Node3D = workbench.building_nodes[&"house_l"]
	workbench._on_seed_changed(77.0)
	_check(selected.seed == 77 and workbench.building_nodes[&"house_l"] != before_seed, "细节种子修改应立即自动重建当前建筑")
	workbench.undo_redo.undo()
	var move_origin: Vector2 = selected.polygon[0]
	var tracked_connector: PCGSkybridgeConnector = workbench.plan.get_connector(&"conn_l_tower")
	var anchor_before: Vector3 = tracked_connector.anchor(selected)["position"]
	workbench._on_building_move_started(selected.id)
	workbench._on_building_moved(selected.id, Vector2(0.5, 0.25))
	workbench._on_building_move_finished(selected.id)
	_check(selected.polygon[0].distance_to(move_origin + Vector2(0.5, 0.25)) < 0.001 and workbench.building_nodes[&"house_tower"] == untouched, "整栋平移应移动轮廓且不重建其他建筑")
	var anchor_after: Vector3 = tracked_connector.anchor(selected)["position"]
	_check((anchor_after - anchor_before).distance_to(Vector3(0.5, 0.0, 0.25)) < 0.001, "主体平移时其廊桥结合点必须跟随")
	workbench.undo_redo.undo()
	_check(workbench.plan.get_footprint(&"house_l").polygon[0].distance_to(move_origin) < 0.001, "撤销平移应恢复建筑原始位置")
	var building_before: Node3D = workbench.building_nodes[selected.id]
	var outline_before := selected.polygon.duplicate()
	workbench._set_editor_mode(PCGBuildingPlanEditor.InteractionMode.BRIDGE_NODE, "桥节点测试")
	var active_bridge: PCGSkybridgeDefinition = workbench.plan.get_skybridge(&"bridge_demo")
	var bridge_point: Vector3 = active_bridge.node_positions()[1]
	bridge_point.x += 0.5
	workbench._on_bridge_node_moved(active_bridge.id, 1, bridge_point)
	_check(workbench.building_nodes[selected.id] == building_before and selected.polygon == outline_before, "桥节点编辑不得重建或修改建筑主体")
	_check(workbench.plan_editor.interaction_mode == PCGBuildingPlanEditor.InteractionMode.BRIDGE_NODE, "模式切换应明确隔离主体与廊桥编辑")
	var old_height: float = selected.height()
	workbench._on_floors_changed(6.0)
	_check(selected.floors == 6 and selected.height() > old_height, "楼层参数应改变建筑高度")
	workbench.undo_redo.undo()
	_check(workbench.plan.get_footprint(&"house_l").floors == 4, "撤销应恢复楼层参数")
	workbench.undo_redo.redo()
	_check(workbench.plan.get_footprint(&"house_l").floors == 6, "重做应恢复新楼层参数")
	var before_count: int = workbench.plan.footprints.size()
	workbench._select_footprint(&"house_l")
	workbench._split_selected()
	_check(workbench.plan.footprints.size() == before_count and String(workbench.status_label.text).contains("结合点"),
		"带廊桥结合点的建筑必须明确拒绝切分并提示")
	workbench.plan.connectors.clear()
	workbench.plan.skybridges.clear()
	workbench._sync_plan()
	workbench._split_selected()
	_check(workbench.plan.footprints.size() == before_count + 1, "切分应新增一个独立面岛")
	_check(workbench.plan.get_footprint(&"house_l") != null, "切分应保留原建筑 ID")
	workbench.undo_redo.undo()
	_check(workbench.plan.footprints.size() == before_count, "撤销切分应恢复原平面")
	workbench._add_footprint()
	_check(workbench.plan.footprints.size() == before_count + 1, "新增面岛应使用完整默认组件绑定")
	var added: PCGBuildingFootprint = workbench.plan.get_footprint(&"house_4")
	_check(not _has_building_overlap(workbench.plan, added.id), "新增建筑不得与现有建筑轮廓重叠")
	var added_center: Vector2 = workbench._polygon_bounds(added.normalized_polygon()).get_center()
	var existing_density := 0.0
	for existing in workbench.plan.footprints:
		if existing.id != added.id:
			existing_density = maxf(existing_density, workbench._density_at(workbench._polygon_bounds(existing.normalized_polygon()).get_center()))
	_check(workbench._density_at(added_center) < existing_density, "新增位置应低于现有密集区域的密度")
	var added_data := added.semantic_data()
	workbench._add_footprint()
	var next_added: PCGBuildingFootprint = workbench.plan.get_footprint(&"house_5")
	_check(next_added != null and next_added.semantic_data() != added_data, "连续新建应产生不同的轮廓和参数")
	workbench.undo_redo.undo()
	_check(workbench.plan.footprints.size() == before_count + 1, "连续新建撤销一次应只移除后一栋")
	workbench.undo_redo.undo()
	_check(workbench.plan.footprints.size() == before_count, "撤销新增应删除新面岛")
	workbench._add_footprint()
	_check(workbench.plan.get_footprint(&"house_4").semantic_data() == added_data, "相同平面与新建 ID 应复现相同建筑")
	workbench.undo_redo.undo()
	workbench._delete_selected()
	_check(workbench.plan.footprints.size() == before_count - 1, "删除应移除选中面岛")
	workbench.undo_redo.undo()
	_check(workbench.plan.footprints.size() == before_count, "撤销删除应恢复全部生成输入")
	workbench.plan.connectors.clear()
	workbench.plan.skybridges.clear()
	var first := PCGBuildingFootprint.new()
	first.id = &"fuse_a"
	first.polygon = PackedVector2Array([Vector2(-1, -1), Vector2(1, -1), Vector2(1, 1), Vector2(-1, 1)])
	var other_footprint := PCGBuildingFootprint.new()
	other_footprint.id = &"fuse_b"
	other_footprint.polygon = PackedVector2Array([Vector2(0, -1), Vector2(2, -1), Vector2(2, 1), Vector2(0, 1)])
	workbench.plan.footprints.assign([first, other_footprint])
	workbench._set_editor_mode(PCGBuildingPlanEditor.InteractionMode.FOOTPRINT, "主体融合测试")
	workbench._sync_plan()
	workbench._select_footprint(first.id)
	_check(workbench.fusion_button.disabled, "单选建筑时融合按钮必须禁用")
	var multi_press := InputEventMouseButton.new()
	multi_press.button_index = MOUSE_BUTTON_LEFT
	multi_press.pressed = true
	multi_press.shift_pressed = true
	multi_press.position = workbench.plan_editor.world_to_screen(Vector2(1.0, 0.0))
	workbench.plan_editor._gui_input(multi_press)
	var multi_release := InputEventMouseButton.new()
	multi_release.button_index = MOUSE_BUTTON_LEFT
	multi_release.pressed = false
	multi_release.shift_pressed = true
	multi_release.position = multi_press.position
	workbench.plan_editor._gui_input(multi_release)
	_check(workbench.selected_ids.size() == 2 and not workbench.fusion_button.disabled, "Shift 多选相交建筑后融合按钮必须启用")
	workbench._fuse_selected()
	var fused: PCGBuildingFootprint = workbench.plan.get_footprint(&"fuse_b")
	_check(workbench.plan.footprints.size() == 1 and fused != null and absf(PCGBuildingFootprint.signed_area(fused.polygon)) > 4.0, "选中的相交建筑应融合为更大的单一轮廓")
	_check(workbench.fusion_button.disabled, "融合完成恢复单选后按钮应重新禁用")
	workbench.undo_redo.undo()
	_check(workbench.plan.footprints.size() == 2, "撤销融合应恢复两栋独立建筑")
	first = workbench.plan.get_footprint(&"fuse_a")
	workbench._toggle_terrain()
	var foundation := workbench.building_nodes[first.id].get_node_or_null("SlopeFoundation") as MeshInstance3D
	_check(foundation != null and first.ground_elevation > 0.0, "斜坡应生成基础并设置建筑基准标高")
	_check(foundation != null and inspector.inspect_mesh(foundation.mesh)["ok"], "斜坡基础必须为封闭无退化 Mesh")
	var base_before: float = first.ground_elevation
	workbench._on_building_move_started(first.id)
	workbench._on_building_moved(first.id, Vector2(1.0, 0.0))
	workbench._on_building_move_finished(first.id)
	_check(first.ground_elevation > base_before, "斜坡上平移建筑应重新计算基准标高")
	workbench._toggle_terrain()
	_check(is_zero_approx(first.ground_elevation), "关闭斜坡后建筑应回到水平地面")
	var pan_origin: Vector2 = workbench.plan_editor.world_to_screen(Vector2.ZERO)
	var pan_press := InputEventMouseButton.new()
	pan_press.button_index = MOUSE_BUTTON_RIGHT
	pan_press.pressed = true
	pan_press.position = Vector2(20.0, 20.0)
	workbench.plan_editor._gui_input(pan_press)
	var pan_motion := InputEventMouseMotion.new()
	pan_motion.position = Vector2(52.0, 38.0)
	pan_motion.relative = Vector2(32.0, 18.0)
	workbench.plan_editor._gui_input(pan_motion)
	var pan_release := InputEventMouseButton.new()
	pan_release.button_index = MOUSE_BUTTON_RIGHT
	pan_release.pressed = false
	workbench.plan_editor._gui_input(pan_release)
	var pan_end: Vector2 = workbench.plan_editor.world_to_screen(Vector2.ZERO)
	_check(pan_end.distance_to(pan_origin + Vector2(32.0, 18.0)) < 0.001, "顶视图右键拖动应平移坐标原点")
	var zoom_position := Vector2(180.0, 120.0)
	var zoom_anchor: Vector2 = workbench.plan_editor.screen_to_world(zoom_position)
	workbench.plan_editor.zoom_at(zoom_position, 1.5)
	_check(workbench.plan_editor.world_to_screen(zoom_anchor).distance_to(zoom_position) < 0.01, "光标中心缩放不得让世界锚点漂移")
	workbench.plan_editor.fit_to_content()
	_check(_all_footprints_visible(workbench.plan_editor), "适配全部应把全部建筑轮廓收入视口")
	workbench._open_detail_window()
	_check(workbench.detail_window.visible and workbench.detail_plan_editor.plan == workbench.plan, "独立窗口应共享同一份可编辑平面")
	workbench.detail_plan_editor.footprint_selected.emit(&"house_tower", false)
	_check(workbench.selected_id == &"house_tower" and workbench.plan_editor.selected_id == &"house_tower", "独立窗口选择应同步回原顶视图")
	workbench.detail_window.hide()
	_check(not workbench.detail_window.visible, "独立窗口关闭应保留主工作台")
	var old_yaw: float = workbench.camera_yaw
	var old_pitch: float = workbench.camera_pitch
	var orbit_press := InputEventMouseButton.new()
	orbit_press.button_index = MOUSE_BUTTON_RIGHT
	orbit_press.pressed = true
	orbit_press.position = Vector2(700.0, 500.0)
	workbench._input(orbit_press)
	var orbit_motion := InputEventMouseMotion.new()
	orbit_motion.position = Vector2(780.0, 524.0)
	orbit_motion.relative = Vector2(80.0, 24.0)
	workbench._input(orbit_motion)
	var orbit_release := InputEventMouseButton.new()
	orbit_release.button_index = MOUSE_BUTTON_RIGHT
	orbit_release.pressed = false
	workbench._input(orbit_release)
	_check(workbench.camera_yaw != old_yaw and workbench.camera_pitch != old_pitch, "顶视图外右键拖动应环绕三维相机")
	_check(not workbench.orbiting, "右键释放后应结束三维环绕")
	var target_before: Vector3 = workbench.camera_target
	orbit_press.button_index = MOUSE_BUTTON_MIDDLE
	orbit_press.pressed = true
	workbench._input(orbit_press)
	orbit_motion.position = Vector2(740.0, 540.0)
	workbench._input(orbit_motion)
	orbit_release.button_index = MOUSE_BUTTON_MIDDLE
	orbit_release.pressed = false
	workbench._input(orbit_release)
	_check(workbench.camera_target.distance_to(target_before) > 0.01, "主视图中键拖动应平移相机目标点")
	_check(not workbench.camera_panning, "中键释放后应结束主视图平移")
	if DisplayServer.get_name() != "headless":
		var event_yaw: float = workbench.camera_yaw
		orbit_press.button_index = MOUSE_BUTTON_RIGHT
		orbit_release.button_index = MOUSE_BUTTON_RIGHT
		orbit_press.position = Vector2(700.0, 500.0)
		orbit_press.global_position = orbit_press.position
		Input.parse_input_event(orbit_press)
		await process_frame
		orbit_motion.position = Vector2(760.0, 510.0)
		orbit_motion.global_position = orbit_motion.position
		orbit_motion.button_mask = MOUSE_BUTTON_MASK_RIGHT
		Input.parse_input_event(orbit_motion)
		await process_frame
		orbit_release.position = orbit_motion.position
		orbit_release.global_position = orbit_motion.position
		Input.parse_input_event(orbit_release)
		await process_frame
		_check(workbench.camera_yaw != event_yaw and not workbench.orbiting, "真实输入队列应完成右键环绕并释放")
		var event_target: Vector3 = workbench.camera_target
		orbit_press.button_index = MOUSE_BUTTON_MIDDLE
		orbit_press.pressed = true
		Input.parse_input_event(orbit_press)
		await process_frame
		orbit_motion.position = Vector2(760.0, 540.0)
		orbit_motion.global_position = orbit_motion.position
		orbit_motion.button_mask = MOUSE_BUTTON_MASK_MIDDLE
		Input.parse_input_event(orbit_motion)
		await process_frame
		orbit_release.button_index = MOUSE_BUTTON_MIDDLE
		orbit_release.pressed = false
		orbit_release.position = orbit_motion.position
		orbit_release.global_position = orbit_motion.position
		Input.parse_input_event(orbit_release)
		await process_frame
		_check(workbench.camera_target.distance_to(event_target) > 0.01 and not workbench.camera_panning, "真实输入队列应完成中键平移并释放")
	# 连续拖动同一建筑应经 merge_key 合并为一条历史，一次撤销回到拖动起点。
	workbench.undo_redo.clear_history()
	workbench._select_footprint(&"fuse_a")
	var drag_origin: Vector2 = workbench.plan.get_footprint(&"fuse_a").polygon[0]
	workbench._on_building_move_started(&"fuse_a")
	workbench._on_building_moved(&"fuse_a", Vector2(0.5, 0.0))
	workbench._on_building_move_finished(&"fuse_a")
	workbench._on_building_move_started(&"fuse_a")
	workbench._on_building_moved(&"fuse_a", Vector2(0.5, 0.0))
	workbench._on_building_move_finished(&"fuse_a")
	_check(workbench.session.history.committed_count() == 1, "连续拖动应合并为一条历史")
	workbench.undo_redo.undo()
	_check(workbench.plan.get_footprint(&"fuse_a").polygon[0].distance_to(drag_origin) < 0.001,
		"一次撤销应回到连续拖动起点")
	workbench.undo_redo.redo()
	_check(workbench.plan.get_footprint(&"fuse_a").polygon[0].distance_to(drag_origin + Vector2(1.0, 0.0)) < 0.001,
		"重做应恢复合并后的最终位置")
	workbench.undo_redo.undo()
	# 带结合点的建筑必须安全拒绝切分：不产生历史、平面不变、空历史撤销无副作用。
	workbench.undo_redo.clear_history()
	var guard_connector := PCGSkybridgeConnector.new()
	guard_connector.id = &"conn_split_guard"
	guard_connector.building_id = &"fuse_a"
	guard_connector.edge_index = 0
	guard_connector.edge_t = 0.5
	guard_connector.floor = 0
	workbench.plan.connectors.append(guard_connector)
	workbench._sync_plan()
	workbench._select_footprint(&"fuse_a")
	var guard_count: int = workbench.plan.footprints.size()
	workbench._split_selected()
	_check(workbench.plan.footprints.size() == guard_count and String(workbench.status_label.text).contains("结合点"),
		"带结合点建筑切分被拒绝后平面应保持不变")
	_check(workbench.session.history.committed_count() == 0, "被拒绝的切分不应进入撤销历史")
	workbench.undo_redo.undo()
	_check(workbench.plan.get_footprint(&"fuse_a") != null and workbench.plan.footprints.size() == guard_count,
		"空历史撤销不得破坏平面")
	workbench.plan.connectors.clear()
	workbench._sync_plan()
	workbench._split_selected()
	_check(workbench.plan.footprints.size() == guard_count + 1, "移除结合点后应可正常切分")
	workbench.undo_redo.undo()
	_check(workbench.plan.footprints.size() == guard_count, "撤销切分应恢复原平面")
	workbench.undo_redo.clear_history()
	workbench.queue_free()
	result["root"].free()
	second["root"].free()
	await process_frame
	if failures.is_empty():
		print("BUILDING_TEST_RESULT: PASS checks=%d" % checks)
		quit(0)
	else:
		for failure in failures:
			push_error("BUILDING_TEST: " + failure)
		print("BUILDING_TEST_RESULT: FAIL checks=%d failures=%d" % [checks, failures.size()])
		quit(1)

func DefinitionRole(role: String) -> int:
	return PCGBuildingComponentDefinition.Role[role]

func _mesh_triangles(mesh: Mesh) -> int:
	var count := 0
	for surface in mesh.get_surface_count():
		var indices = mesh.surface_get_arrays(surface)[Mesh.ARRAY_INDEX]
		count += int(indices.size() / 3) if indices != null else 0
	return count

func _role_counts(root: Node3D) -> Dictionary:
	var counts: Dictionary = {}
	for building in root.get_children():
		var components := building as Node if building.name == "StandardComponents" else building.get_node_or_null("StandardComponents")
		if components == null:
			continue
		for component in components.get_children():
			var role: int = component.get_meta("component_role")
			counts[role] = int(counts.get(role, 0)) + 1
	return counts

func _meta_counts(root: Node3D, key: StringName) -> Dictionary:
	var counts: Dictionary = {}
	for building in root.get_children():
		var components := building.get_node("StandardComponents")
		for component in components.get_children():
			var value: StringName = component.get_meta(key)
			counts[value] = int(counts.get(value, 0)) + 1
	return counts

func _decoration_overlap_count(root: Node3D, generator: PCGBuildingGenerator,
			catalog: PCGBuildingComponentCatalog) -> int:
	var overlaps := 0
	var roles := [
		PCGBuildingComponentDefinition.Role.WINDOW,
		PCGBuildingComponentDefinition.Role.DOOR,
		PCGBuildingComponentDefinition.Role.AWNING,
		PCGBuildingComponentDefinition.Role.WINDOW_DRYING_ROD,
		PCGBuildingComponentDefinition.Role.BALCONY,
		PCGBuildingComponentDefinition.Role.DOUBLE_DOOR,
	]
	for building in root.get_children():
		var records: Array[Dictionary] = []
		for component in building.get_node("StandardComponents").get_children():
			if not roles.has(component.get_meta("component_role")):
				continue
			var definition := catalog.get_definition(component.get_meta("component_id"))
			var bounds: AABB = generator._component_bounds(definition, component.transform, Vector3.ONE)
			var host_id: StringName = component.get_meta("host_window_id", &"")
			if host_id.is_empty() and component.get_meta("component_role") == PCGBuildingComponentDefinition.Role.WINDOW:
				host_id = component.get_meta("slot_id", &"")
			for other in records:
				if not host_id.is_empty() and other["host_id"] == host_id:
					continue
				if bounds.grow(-0.02).intersects(other["bounds"]):
					overlaps += 1
					print("FACADE_OVERLAP ", building.name, ": ", other["id"], " / ", component.get_meta("component_id"), " host=", host_id)
			records.append({"bounds": bounds, "host_id": host_id, "id": component.get_meta("component_id")})
	return overlaps

func _decorations_have_valid_hosts(root: Node3D) -> bool:
	for building in root.get_children():
		var slots: Dictionary = {}
		var components := building.get_node("StandardComponents")
		for component in components.get_children():
			if component.get_meta("component_role") == PCGBuildingComponentDefinition.Role.WINDOW:
				slots[component.get_meta("slot_id", &"")] = true
		for component in components.get_children():
			if not component.get_meta("component_role") in [
				PCGBuildingComponentDefinition.Role.AWNING,
				PCGBuildingComponentDefinition.Role.WINDOW_DRYING_ROD,
				PCGBuildingComponentDefinition.Role.BALCONY,
			]:
				continue
			var host_id: StringName = component.get_meta("host_window_id", &"")
			if host_id.is_empty() or not slots.has(host_id):
				return false
	return true

func _entrances_hit_other_buildings(root: Node3D, plan: PCGBuildingPlan,
			generator: PCGBuildingGenerator, catalog: PCGBuildingComponentCatalog) -> bool:
	for building in root.get_children():
		for component in building.get_node("StandardComponents").get_children():
			if not component.get_meta("component_role") in [PCGBuildingComponentDefinition.Role.DOOR, PCGBuildingComponentDefinition.Role.DOUBLE_DOOR]:
				continue
			var definition := catalog.get_definition(component.get_meta("component_id"))
			var bounds: AABB = generator._component_bounds(definition, component.transform, Vector3.ONE)
			if generator._hits_obstacles(bounds, building.get_meta("footprint_id"), plan.footprints):
				return true
	return false

func _roof_racks_fit(root: Node3D, plan: PCGBuildingPlan,
			generator: PCGBuildingGenerator, catalog: PCGBuildingComponentCatalog) -> bool:
	for building in root.get_children():
		var rack: MeshInstance3D = null
		var hatch: MeshInstance3D = null
		for component in building.get_node("StandardComponents").get_children():
			if component.get_meta("component_role") == PCGBuildingComponentDefinition.Role.ROOF_DRYING_RACK:
				rack = component
			elif component.get_meta("component_role") == PCGBuildingComponentDefinition.Role.ROOF_HATCH:
				hatch = component
		if rack == null:
			continue
		var footprint := plan.get_footprint(building.get_meta("footprint_id"))
		var parapet := catalog.get_definition(footprint.parapet_component_id)
		var usable_parts := Geometry2D.offset_polygon(footprint.normalized_polygon(), -(parapet.size.z * 0.5 + 0.12), Geometry2D.JOIN_MITER)
		var bounds := generator._component_bounds(catalog.get_definition(rack.get_meta("component_id")), rack.transform, Vector3.ONE)
		var rect := PackedVector2Array([
			Vector2(bounds.position.x, bounds.position.z), Vector2(bounds.end.x, bounds.position.z),
			Vector2(bounds.end.x, bounds.end.z), Vector2(bounds.position.x, bounds.end.z),
		])
		var fits := false
		for usable in usable_parts:
			fits = fits or generator._rect_inside_polygon(rect, usable)
		if not fits:
			return false
		if hatch != null:
			var hatch_bounds := generator._component_bounds(catalog.get_definition(hatch.get_meta("component_id")), hatch.transform, Vector3.ONE)
			if bounds.grow(-0.02).intersects(hatch_bounds):
				return false
	return true

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

func _has_building_overlap(plan: PCGBuildingPlan, id: StringName) -> bool:
	var target := plan.get_footprint(id)
	if target == null:
		return false
	for other in plan.footprints:
		if other == null or other.id == id:
			continue
		for part in Geometry2D.intersect_polygons(target.normalized_polygon(), other.normalized_polygon()):
			if absf(PCGBuildingFootprint.signed_area(part)) > 0.001:
				return true
	return false

func _all_footprints_visible(editor: PCGBuildingPlanEditor) -> bool:
	for footprint in editor.plan.footprints:
		for point in footprint.normalized_polygon():
			var screen := editor.world_to_screen(point)
			if screen.x < 0.0 or screen.y < 0.0 or screen.x > editor.size.x or screen.y > editor.size.y:
				return false
	return true

func _signed_volume(mesh: Mesh) -> float:
	var volume := 0.0
	for surface in mesh.get_surface_count():
		var arrays := mesh.surface_get_arrays(surface)
		var vertices: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
		var indices: PackedInt32Array = arrays[Mesh.ARRAY_INDEX]
		for index in range(0, indices.size(), 3):
			volume += vertices[indices[index]].dot(vertices[indices[index + 1]].cross(vertices[indices[index + 2]])) / 6.0
	return volume

func _check(condition: bool, message: String) -> void:
	checks += 1
	if not condition:
		failures.append(message)
