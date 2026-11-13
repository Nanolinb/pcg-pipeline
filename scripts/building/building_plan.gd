@tool
class_name PCGBuildingPlan
extends Resource

@export var master_seed: String = "fantasy-city-v1"
@export var terrain_slope := Vector2.ZERO
@export var footprints: Array[PCGBuildingFootprint] = []
@export var connectors: Array[PCGSkybridgeConnector] = []
@export var skybridges: Array[PCGSkybridgeDefinition] = []

func validation_errors() -> PackedStringArray:
	var errors := PackedStringArray()
	var ids: Dictionary = {}
	for footprint in footprints:
		if footprint == null:
			errors.append("平面包含空建筑。")
			continue
		for issue in footprint.validation_errors():
			errors.append("%s：%s" % [footprint.id, issue])
		if ids.has(footprint.id):
			errors.append("重复建筑 ID：%s。" % footprint.id)
		ids[footprint.id] = true
	var connector_ids: Dictionary = {}
	for connector in connectors:
		if connector == null:
			errors.append("平面包含空结合点。")
			continue
		for issue in connector.validation_errors(get_footprint(connector.building_id)):
			errors.append("%s：%s" % [connector.id, issue])
		if connector_ids.has(connector.id):
			errors.append("重复结合点 ID：%s。" % connector.id)
		connector_ids[connector.id] = true
	var bridge_ids: Dictionary = {}
	for bridge in skybridges:
		if bridge == null:
			errors.append("平面包含空廊桥。")
			continue
		for issue in bridge.validation_errors():
			errors.append("%s：%s" % [bridge.id, issue])
		if bridge_ids.has(bridge.id):
			errors.append("重复廊桥 ID：%s。" % bridge.id)
		bridge_ids[bridge.id] = true
		if not connector_ids.has(bridge.connector_a) or not connector_ids.has(bridge.connector_b):
			errors.append("廊桥 %s 引用了不存在的结合点。" % bridge.id)
	return errors

func get_footprint(id: StringName) -> PCGBuildingFootprint:
	for footprint in footprints:
		if footprint != null and footprint.id == id:
			return footprint
	return null

func get_connector(id: StringName) -> PCGSkybridgeConnector:
	for connector in connectors:
		if connector != null and connector.id == id:
			return connector
	return null

func get_skybridge(id: StringName) -> PCGSkybridgeDefinition:
	for bridge in skybridges:
		if bridge != null and bridge.id == id:
			return bridge
	return null

func connectors_for_building(id: StringName) -> Array[PCGSkybridgeConnector]:
	var result: Array[PCGSkybridgeConnector] = []
	for connector in connectors:
		if connector != null and connector.building_id == id:
			result.append(connector)
	return result

# 建筑立面开窗避让区：完整生成（build_plan）与增量重建（workbench）共用同一来源。
func facade_exclusions_for(id: StringName) -> Array:
	var footprint := get_footprint(id)
	var result: Array = []
	if footprint == null:
		return result
	for connector in connectors_for_building(id):
		result.append(connector.exclusion(footprint))
	return result

# 单栋建筑的生成输入签名：生成器 semantic_digest 与工作台脏检查共用同一来源，
# 结合点/避让区变化必须能触发对应建筑的增量重建。
func facade_signature_for(id: StringName) -> Dictionary:
	var footprint := get_footprint(id)
	if footprint == null:
		return {}
	var connector_data: Array = []
	for connector in connectors_for_building(id):
		connector_data.append(connector.semantic_data())
	return {
		"building": footprint.semantic_data(),
		"terrain": [terrain_slope.x, terrain_slope.y],
		"exclusions": facade_exclusions_for(id),
		"connectors": connector_data,
	}

func skybridges_for_building(id: StringName) -> Array[PCGSkybridgeDefinition]:
	var result: Array[PCGSkybridgeDefinition] = []
	for bridge in skybridges:
		if bridge == null:
			continue
		var first := get_connector(bridge.connector_a)
		var second := get_connector(bridge.connector_b)
		if (first != null and first.building_id == id) or (second != null and second.building_id == id):
			result.append(bridge)
	return result

func terrain_height_at(point: Vector2) -> float:
	return terrain_slope.dot(point)

func semantic_data() -> Dictionary:
	var items: Array = []
	for footprint in footprints:
		if footprint != null:
			items.append(footprint.semantic_data())
	var connector_items: Array = []
	for connector in connectors:
		if connector != null:
			connector_items.append(connector.semantic_data())
	var bridge_items: Array = []
	for bridge in skybridges:
		if bridge != null:
			bridge_items.append(bridge.semantic_data())
	return {
		"master_seed": master_seed,
		"terrain_slope": [terrain_slope.x, terrain_slope.y],
		"footprints": items,
		"connectors": connector_items,
		"skybridges": bridge_items,
	}

static func demo() -> PCGBuildingPlan:
	var plan := PCGBuildingPlan.new()
	var main_house := PCGBuildingFootprint.new()
	main_house.id = &"house_l"
	main_house.polygon = PackedVector2Array([
		Vector2(-3.2, -2.0), Vector2(0.2, -2.0), Vector2(0.2, 0.0),
		Vector2(2.0, 0.0), Vector2(2.0, 2.2), Vector2(-3.2, 2.2),
	])
	main_house.floors = 4
	main_house.wall_color = Color("c7ad8b")
	main_house.wall_material_id = &"building/wall/sand"
	main_house.use_double_entrance = true
	var tower := PCGBuildingFootprint.new()
	tower.id = &"house_tower"
	tower.polygon = PackedVector2Array([
		Vector2(3.6, -2.4), Vector2(5.8, -2.4),
		Vector2(5.8, -0.2), Vector2(3.6, -0.2),
	])
	tower.floors = 6
	tower.seed = 7
	tower.wall_color = Color("b98065")
	tower.wall_material_id = &"building/wall/clay"
	var annex := PCGBuildingFootprint.new()
	annex.id = &"house_annex"
	annex.polygon = PackedVector2Array([
		Vector2(-0.8, 3.4), Vector2(2.2, 3.4),
		Vector2(2.2, 5.2), Vector2(-0.8, 5.2),
	])
	annex.floors = 2
	annex.seed = 13
	annex.wall_color = Color("a8b1a0")
	annex.wall_material_id = &"building/wall/plaster"
	plan.footprints.assign([main_house, tower, annex])
	return plan
