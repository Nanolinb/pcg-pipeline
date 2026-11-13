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
	var role_counts := _role_counts(result["root"])
	_check(role_counts.get(DefinitionRole("DOOR"), 0) == 2, "两栋建筑应保留单门入口")
	_check(role_counts.get(DefinitionRole("DOUBLE_DOOR"), 0) == 1, "主建筑应使用带遮阳顶的双门入口")
	_check(role_counts.get(DefinitionRole("WINDOW"), 0) > 20, "立面应生成窗户阵列")
	_check(role_counts.get(DefinitionRole("PARAPET"), 0) == 14, "女儿墙应覆盖全部轮廓边")
	_check(role_counts.get(DefinitionRole("ROOF_HATCH"), 0) == 3, "每栋建筑应有屋顶组件")
	_check(role_counts.get(DefinitionRole("ROOF_DRYING_RACK"), 0) == 3, "有效屋顶应生成晾衣架")
	_check(role_counts.get(DefinitionRole("BALCONY"), 0) >= 3, "每栋建筑应至少有一个小阳台")
	var component_ids := _meta_counts(result["root"], "component_id")
	_check(component_ids.get(&"window_drying_rod_basic", 0) > 0, "立面应包含空晾衣杆")
	_check(component_ids.get(&"window_drying_clothes_basic", 0) > 0, "立面应包含带衣服的晾衣杆")
	_check(_decoration_overlap_count(result["root"], generator, catalog) == 0, "门、窗、阳台和立面装饰不得互相重叠")
	_check(_decorations_have_valid_hosts(result["root"]), "装饰必须依附于实际通过检查的宿主窗户")
	var corner_polygon := plan.get_footprint(&"house_l").normalized_polygon()
	_check(not generator._corner_clearance(corner_polygon, 2, 0.02, catalog.get_definition(&"window_basic")), "凹角附近的窗户必须被净空规则拒绝")
	_check(not _entrances_hit_other_buildings(result["root"], plan, generator, catalog), "入口及遮阳顶不得插入其他建筑")
	plan.get_footprint(&"house_l").window_component_id = &"missing_window"
	var invalid := generator.build_plan(plan, catalog)
	_check(invalid["root"] == null and not invalid["errors"].is_empty(), "缺失组件必须拒绝生成且不留半份结果")
	plan.get_footprint(&"house_l").window_component_id = &"window_basic"
	plan.get_footprint(&"house_l").polygon = PackedVector2Array([
		Vector2.ZERO, Vector2(2.0, 2.0), Vector2(0.0, 2.0), Vector2(2.0, 0.0),
	])
	_check(not plan.validation_errors().is_empty(), "自交平面必须被校验拦截")
	plan = PCGBuildingPlan.demo()

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
	var old_height: float = selected.height()
	workbench._on_floors_changed(6.0)
	_check(selected.floors == 6 and selected.height() > old_height, "楼层参数应改变建筑高度")
	workbench.undo_redo.undo()
	_check(workbench.plan.get_footprint(&"house_l").floors == 4, "撤销应恢复楼层参数")
	workbench.undo_redo.redo()
	_check(workbench.plan.get_footprint(&"house_l").floors == 6, "重做应恢复新楼层参数")
	var before_count: int = workbench.plan.footprints.size()
	workbench._split_selected()
	_check(workbench.plan.footprints.size() == before_count + 1, "切分应新增一个独立面岛")
	_check(workbench.plan.get_footprint(&"house_l") != null, "切分应保留原建筑 ID")
	workbench.undo_redo.undo()
	_check(workbench.plan.footprints.size() == before_count, "撤销切分应恢复原平面")
	workbench._add_footprint()
	_check(workbench.plan.footprints.size() == before_count + 1, "新增面岛应使用完整默认组件绑定")
	workbench.undo_redo.undo()
	_check(workbench.plan.footprints.size() == before_count, "撤销新增应删除新面岛")
	workbench._delete_selected()
	_check(workbench.plan.footprints.size() == before_count - 1, "删除应移除选中面岛")
	workbench.undo_redo.undo()
	_check(workbench.plan.footprints.size() == before_count, "撤销删除应恢复全部生成输入")
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
	workbench.detail_plan_editor.footprint_selected.emit(&"house_tower")
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
	if DisplayServer.get_name() != "headless":
		var event_yaw: float = workbench.camera_yaw
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

func _role_counts(root: Node3D) -> Dictionary:
	var counts: Dictionary = {}
	for building in root.get_children():
		var components := building.get_node("StandardComponents")
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
