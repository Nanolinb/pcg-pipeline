@tool
class_name PCGBuildingFootprint
extends Resource

@export var id: StringName = &""
@export var polygon := PackedVector2Array()
@export_range(1, 12, 1) var floors: int = 3
@export_range(2.0, 5.0, 0.05) var floor_height: float = 2.6
@export var seed: int = 1
@export var wall_color := Color("bca78c")
@export var wall_material_id: StringName = &"building/wall/default"
@export var window_component_id: StringName = &"window_basic"
@export var door_component_id: StringName = &"door_basic"
@export var parapet_component_id: StringName = &"parapet_basic"
@export var corner_component_id: StringName = &"corner_post_basic"
@export var awning_component_id: StringName = &"awning_basic"
@export var roof_component_id: StringName = &"roof_hatch_basic"
@export var roof_drying_component_id: StringName = &"roof_drying_rack_basic"
@export var balcony_component_id: StringName = &"balcony_basic"
@export var double_door_component_id: StringName = &"double_door_canopy_basic"
@export var use_double_entrance: bool = false

func normalized_polygon() -> PackedVector2Array:
	var result := PackedVector2Array()
	for point in polygon:
		if result.is_empty() or result[-1].distance_squared_to(point) > 0.000001:
			result.append(point)
	if result.size() > 1 and result[0].distance_squared_to(result[-1]) <= 0.000001:
		result.remove_at(result.size() - 1)
	if signed_area(result) < 0.0:
		result.reverse()
	return result

func height() -> float:
	return float(floors) * floor_height

func validation_errors() -> PackedStringArray:
	var errors := PackedStringArray()
	if id.is_empty():
		errors.append("建筑 ID 不能为空。")
	var normalized := normalized_polygon()
	if normalized.size() < 3:
		errors.append("平面轮廓至少需要三个不同顶点。")
		return errors
	if absf(signed_area(normalized)) < 0.05:
		errors.append("平面轮廓面积必须大于 0.05 平方米。")
	for index in normalized.size():
		var next := (index + 1) % normalized.size()
		if normalized[index].distance_to(normalized[next]) < 0.05:
			errors.append("平面轮廓包含过短的边：%d。" % index)
		for other in range(index + 1, normalized.size()):
			if other == index or other == next or (index == 0 and other == normalized.size() - 1):
				continue
			var other_next := (other + 1) % normalized.size()
			var hit: Variant = Geometry2D.segment_intersects_segment(
				normalized[index], normalized[next], normalized[other], normalized[other_next]
			)
			if hit != null:
				errors.append("平面轮廓存在自交：边 %d 与 %d。" % [index, other])
				return errors
	return errors

func semantic_data() -> Dictionary:
	var points: Array = []
	for point in normalized_polygon():
		points.append([point.x, point.y])
	return {
		"id": String(id),
		"polygon": points,
		"floors": floors,
		"floor_height": floor_height,
		"seed": seed,
		"wall_material_id": String(wall_material_id),
		"use_double_entrance": use_double_entrance,
		"components": [
			String(window_component_id), String(door_component_id),
			String(parapet_component_id), String(corner_component_id),
			String(awning_component_id), String(roof_component_id),
			String(roof_drying_component_id), String(balcony_component_id),
			String(double_door_component_id),
		],
	}

static func signed_area(points: PackedVector2Array) -> float:
	var area := 0.0
	for index in points.size():
		var next := (index + 1) % points.size()
		area += points[index].cross(points[next])
	return area * 0.5
