@tool
class_name PCGSkybridgeDefinition
extends Resource

# 廊桥生成数据：两端结合点 + 可编辑路径节点。
# 每个节点可带贝塞尔手柄（"in"/"out" 相对偏移向量，三倍率参与 Hermite 切向量）；
# 无手柄时退回 tension 控制转弯强度（1.0 自然穿过，0 圆角驻停，>1 加强转弯）。
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
	# 显式设置 tension 时清掉手柄，让 tension 重新生效。
	nodes[index].erase("in")
	nodes[index].erase("out")

func node_handle(index: int, kind: StringName) -> Vector3:
	if index < 0 or index >= nodes.size():
		return Vector3.ZERO
	return nodes[index].get(kind, Vector3.ZERO)

func has_node_handle(index: int, kind: StringName) -> bool:
	return index >= 0 and index < nodes.size() and nodes[index].has(kind)

func set_node_handle(index: int, kind: StringName, offset: Vector3) -> void:
	if index < 0 or index >= nodes.size():
		return
	nodes[index][kind] = offset

# 在路径上离 position 最近的位置插入一个新节点（保留原有节点与手柄），返回新节点索引（失败返回 -1）。
func insert_node_near(position: Vector3, segments_per_span: int = 8) -> int:
	if nodes.size() < 2:
		return -1
	var best_span := 0
	var best_point := Vector3.ZERO
	var best_distance := INF
	for span in nodes.size() - 1:
		var a: Vector3 = nodes[span].get("position", Vector3.ZERO)
		var b: Vector3 = nodes[span + 1].get("position", Vector3.ZERO)
		var ab := b - a
		var length_sq := maxf(ab.length_squared(), 0.000001)
		var u := clampf((position - a).dot(ab) / length_sq, 0.0, 1.0)
		var candidate := a + ab * u
		var distance := candidate.distance_squared_to(position)
		if distance < best_distance:
			best_distance = distance
			best_span = span
			best_point = candidate
	nodes.insert(best_span + 1, {"position": best_point, "tension": 1.0})
	return best_span + 1

# 删除内部节点（端点连接结合点，不可删除）。
func remove_node(index: int) -> bool:
	if index <= 0 or index >= nodes.size() - 1 or nodes.size() <= 2:
		return false
	nodes.remove_at(index)
	return true

# 三次 Hermite 采样；节点带贝塞尔手柄时用手柄导出切向量（m = 3×手柄），否则用 tension。
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
		var m1: Vector3
		if has_node_handle(span, &"out"):
			m1 = node_handle(span, &"out") * 3.0
		else:
			m1 = (p2 - p0) * node_tension(span)
		var m2: Vector3
		if has_node_handle(span + 1, &"in"):
			m2 = -node_handle(span + 1, &"in") * 3.0
		else:
			m2 = (p3 - p1) * node_tension(span + 1)
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
		var entry := {
			"position": [position.x, position.y, position.z],
			"tension": float(node.get("tension", 1.0)),
		}
		if node.has("in"):
			var handle_in: Vector3 = node["in"]
			entry["in"] = [handle_in.x, handle_in.y, handle_in.z]
		if node.has("out"):
			var handle_out: Vector3 = node["out"]
			entry["out"] = [handle_out.x, handle_out.y, handle_out.z]
		node_data.append(entry)
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
