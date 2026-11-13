@tool
class_name PCGSkybridgeDefinition
extends Resource

# 廊桥生成数据：两端结合点 + 可编辑路径节点。
# 节点 tension 控制该处的转弯强度/弧度（1.0 为自然穿过，0 为圆角驻停，>1 为加强转弯）；
# auto_lift 是交叉自动错开时施加的垂直抬升，可经节点编辑继续微调。

@export var id: StringName = &""
@export var connector_a: StringName = &""
@export var connector_b: StringName = &""
@export var component_id: StringName = &"skybridge_basic"
@export var width: float = 1.8
@export var height: float = 2.4
@export var color := Color("7fa8b8")
@export var nodes: Array[Dictionary] = []
@export var auto_lift: float = 0.0

func validation_errors() -> PackedStringArray:
	var errors := PackedStringArray()
	if id.is_empty():
		errors.append("廊桥 ID 不能为空。")
	if connector_a.is_empty() or connector_b.is_empty():
		errors.append("廊桥 %s 必须连接两个结合点。" % id)
	if connector_a == connector_b:
		errors.append("廊桥 %s 的两个结合点不能相同。" % id)
	if width <= 0.0 or height <= 0.0:
		errors.append("廊桥 %s 的截面尺寸必须大于 0。" % id)
	if nodes.size() < 2:
		errors.append("廊桥 %s 至少需要两个路径节点。" % id)
	return errors

func node_positions() -> Array[Vector3]:
	var result: Array[Vector3] = []
	for node in nodes:
		var position: Vector3 = node.get("position", Vector3.ZERO)
		result.append(position + Vector3(0.0, auto_lift, 0.0))
	return result

func set_node_position(index: int, position: Vector3) -> void:
	if index < 0 or index >= nodes.size():
		return
	nodes[index]["position"] = position

func node_tension(index: int) -> float:
	if index < 0 or index >= nodes.size():
		return 1.0
	return float(nodes[index].get("tension", 1.0))

func set_node_tension(index: int, tension: float) -> void:
	if index < 0 or index >= nodes.size():
		return
	nodes[index]["tension"] = tension

# Catmull-Rom 风格三次 Hermite 采样；端点使用单侧差分，tension 缩放该节点切向量。
func sampled_path(segments_per_span: int = 8) -> PackedVector3Array:
	var points := node_positions()
	var result := PackedVector3Array()
	if points.size() < 2:
		return result
	for span in points.size() - 1:
		var p0: Vector3 = points[max(span - 1, 0)]
		var p1: Vector3 = points[span]
		var p2: Vector3 = points[span + 1]
		var p3: Vector3 = points[min(span + 2, points.size() - 1)]
		var m1: Vector3 = (p2 - p0) * node_tension(span)
		var m2: Vector3 = (p3 - p1) * node_tension(span + 1)
		for step in segments_per_span + (0 if span < points.size() - 2 else 1):
			var u := float(step) / float(segments_per_span)
			var u2 := u * u
			var u3 := u2 * u
			result.append(
				p1 * (2.0 * u3 - 3.0 * u2 + 1.0)
				+ m1 * (u3 - 2.0 * u2 + u)
				+ p2 * (-2.0 * u3 + 3.0 * u2)
				+ m2 * (u3 - u2))
	return result

func semantic_data() -> Dictionary:
	var node_data: Array = []
	for node in nodes:
		var position: Vector3 = node.get("position", Vector3.ZERO)
		node_data.append({
			"position": [position.x, position.y, position.z],
			"tension": float(node.get("tension", 1.0)),
		})
	return {
		"id": String(id),
		"connector_a": String(connector_a),
		"connector_b": String(connector_b),
		"component_id": String(component_id),
		"width": width,
		"height": height,
		"auto_lift": auto_lift,
		"nodes": node_data,
	}
