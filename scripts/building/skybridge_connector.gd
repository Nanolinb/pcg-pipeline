@tool
class_name PCGSkybridgeConnector
extends Resource

# 廊桥结合点：附着在建筑某条立面边、某一层的通行开口。
# 结合点是生成数据，正式 Mesh 由 PCGSkybridgeGenerator 从结合点与路径节点重建。

@export var id: StringName = &""
@export var building_id: StringName = &""
@export var edge_index: int = 0
@export_range(0.02, 0.98, 0.01) var edge_t: float = 0.5
@export var floor: int = 1
@export var width: float = 1.2
@export var height: float = 2.4

func validation_errors(footprint: PCGBuildingFootprint = null) -> PackedStringArray:
	var errors := PackedStringArray()
	if id.is_empty():
		errors.append("结合点 ID 不能为空。")
	if building_id.is_empty():
		errors.append("结合点 %s 必须指定建筑。" % id)
	if width <= 0.0 or height <= 0.0:
		errors.append("结合点 %s 的开口尺寸必须大于 0。" % id)
	if footprint != null:
		var polygon := footprint.normalized_polygon()
		if polygon.size() < 3:
			errors.append("结合点 %s 所在建筑轮廓非法。" % id)
		elif edge_index < 0 or edge_index >= polygon.size():
			errors.append("结合点 %s 的边序号 %d 超出轮廓边数 %d。" % [id, edge_index, polygon.size()])
		if floor < 0 or floor >= footprint.floors:
			errors.append("结合点 %s 的楼层 %d 超出建筑层数 %d。" % [id, floor, footprint.floors])
	return errors

# 返回结合点的世界坐标系数据：deck 为桥面（楼层地面）高度，outward 为立面外法线。
func anchor(footprint: PCGBuildingFootprint) -> Dictionary:
	var polygon := footprint.normalized_polygon()
	var index := clampi(edge_index, 0, max(polygon.size() - 1, 0))
	var a := polygon[index]
	var b := polygon[(index + 1) % polygon.size()]
	var edge := b - a
	var outward := Vector3(edge.y, 0.0, -edge.x).normalized()
	var point := a.lerp(b, clampf(edge_t, 0.0, 1.0))
	return {
		"position": Vector3(point.x, footprint.ground_elevation + float(floor) * footprint.floor_height, point.y),
		"outward": outward,
		"edge_length": maxf(edge.length(), 0.001),
		"width": width,
		"height": height,
	}

# 立面开窗避让区（边内 t 区间 + 楼层），供 building_generator 重排窗口。
func exclusion(footprint: PCGBuildingFootprint, margin: float = 0.35) -> Dictionary:
	var data := anchor(footprint)
	var half := (width * 0.5 + margin) / float(data["edge_length"])
	return {
		"edge_index": clampi(edge_index, 0, footprint.normalized_polygon().size() - 1),
		"floor": floor,
		"t0": clampf(edge_t - half, 0.0, 1.0),
		"t1": clampf(edge_t + half, 0.0, 1.0),
	}

func semantic_data() -> Dictionary:
	return {
		"id": String(id),
		"building_id": String(building_id),
		"edge_index": edge_index,
		"edge_t": edge_t,
		"floor": floor,
		"width": width,
		"height": height,
	}
