@tool
class_name PCGWallPanelLayout
extends RefCounted

# 派生墙板布局器：纯数据、确定性的派生器。输入平面轮廓与「实际开口」描述
# （门窗来自生成器实际成功放置的位置，passage 来自 connector 实际门洞），
# 输出按稳定 slot_id 编号的墙板列表。不使用随机数、不求解门窗占用，
# 不替代平面/门窗/廊桥的源数据。

enum PanelKind { SOLID, WINDOW, DOOR, PASSAGE, CORNER }

const KIND_NAMES := {
	PanelKind.SOLID: &"solid",
	PanelKind.WINDOW: &"window",
	PanelKind.DOOR: &"door",
	PanelKind.PASSAGE: &"passage",
	PanelKind.CORNER: &"corner",
}

static func build(building_id: String, polygon: PackedVector2Array, floors: int,
			floor_height: float, panel_width: float, openings: Array = []) -> Dictionary:
	var errors := PackedStringArray()
	var panels: Array[Dictionary] = []
	if polygon.size() < 3:
		errors.append("墙板布局需要至少三个顶点的平面轮廓。")
		return {"panels": panels, "errors": errors}
	if panel_width < 0.4 or panel_width > 4.0:
		errors.append("墙板宽度必须在 0.4 到 4.0 米之间。")
		return {"panels": panels, "errors": errors}
	var by_edge: Dictionary = {}
	for opening in openings:
		var edge_index := int(opening.get("edge_index", -1))
		if edge_index < 0 or edge_index >= polygon.size():
			continue
		if not by_edge.has(edge_index):
			by_edge[edge_index] = []
		by_edge[edge_index].append(opening)
	var floor_count := maxi(1, floors)
	for edge_index in polygon.size():
		var a: Vector2 = polygon[edge_index]
		var b: Vector2 = polygon[(edge_index + 1) % polygon.size()]
		var length := a.distance_to(b)
		if length <= 0.0001:
			continue
		var edge_openings: Array = by_edge.get(edge_index, [])
		var cuts := _edge_cuts(length, panel_width, edge_openings)
		for floor_index in floor_count:
			var y0 := float(floor_index) * floor_height
			var y1 := y0 + floor_height
			for panel_index in range(cuts.size() - 1):
				panels.append(_edge_panel(building_id, edge_index, floor_index,
					panel_index, cuts[panel_index], cuts[panel_index + 1], y0, y1, edge_openings))
	for vertex_index in polygon.size():
		for floor_index in floor_count:
			var y0 := float(floor_index) * floor_height
			panels.append({
				"slot_id": StringName("wall:%s:v%d:f%d" % [building_id, vertex_index, floor_index]),
				"panel_kind": KIND_NAMES[PanelKind.CORNER],
				"building_id": building_id,
				"vertex_index": vertex_index,
				"floor": floor_index,
				"center": polygon[vertex_index],
				"y0": y0,
				"y1": y0 + floor_height,
			})
	return {"panels": panels, "errors": errors}

static func kind_summary(panels: Array) -> Dictionary:
	var summary := {}
	for panel in panels:
		var kind: String = panel["panel_kind"]
		summary[kind] = int(summary.get(kind, 0)) + 1
	return summary

# 每边按 wall_panel_width 定宽划分，末板取余量；余量过小时合并进末板避免碎板。
static func _panel_count(length: float, panel_width: float) -> int:
	var count := maxi(1, int(ceil(length / panel_width - 0.0001)))
	if count > 1 and length - float(count - 1) * panel_width < panel_width * 0.3:
		count -= 1
	return count

static func _edge_cuts(length: float, panel_width: float, openings: Array) -> Array[float]:
	var cuts: Array[float] = [0.0, length]
	var count := _panel_count(length, panel_width)
	for index in range(1, count):
		cuts.append(float(index) * panel_width)
	for opening in openings:
		if _opening_kind(opening) != PanelKind.PASSAGE:
			continue
		cuts.append(clampf(float(opening.get("s0", 0.0)), 0.0, length))
		cuts.append(clampf(float(opening.get("s1", 0.0)), 0.0, length))
	cuts.sort()
	var unique: Array[float] = []
	for cut in cuts:
		if unique.is_empty() or cut > unique[-1] + 0.000001:
			unique.append(cut)
	return unique

# 开口归类取最高优先级：passage > door > window > solid。门窗按中心归属，避免
# 相邻开间互相吞并；通道按实际覆盖归类，且其边界已加入墙板切点。
static func _edge_panel(building_id: String, edge_index: int, floor_index: int,
			panel_index: int, s0: float, s1: float, y0: float, y1: float,
			openings: Array) -> Dictionary:
	var best_priority := 0
	var best_kind := PanelKind.SOLID
	var best_opening := {}
	for opening in openings:
		var o_y0 := float(opening.get("y0", 0.0))
		var o_y1 := float(opening.get("y1", 0.0))
		if o_y1 <= y0 or o_y0 >= y1:
			continue
		var o_s0 := float(opening.get("s0", 0.0))
		var o_s1 := float(opening.get("s1", 0.0))
		if o_s1 <= s0 or o_s0 >= s1:
			continue
		var kind := _opening_kind(opening)
		if kind != PanelKind.PASSAGE:
			var center_s := (o_s0 + o_s1) * 0.5
			var center_y := (o_y0 + o_y1) * 0.5
			if center_s < s0 or center_s >= s1 or center_y < y0 or center_y >= y1:
				continue
		var priority := _kind_priority(kind)
		if priority > best_priority:
			best_priority = priority
			best_kind = kind
			best_opening = opening
	var panel := {
		"slot_id": StringName("wall:%s:e%d:f%d:p%d" % [building_id, edge_index, floor_index, panel_index]),
		"panel_kind": KIND_NAMES[best_kind],
		"building_id": building_id,
		"edge_index": edge_index,
		"floor": floor_index,
		"panel_index": panel_index,
		"s0": s0,
		"s1": s1,
		"y0": y0,
		"y1": y1,
	}
	if best_kind == PanelKind.PASSAGE and not best_opening.is_empty():
		panel["opening"] = {
			"s0": clampf(float(best_opening["s0"]), s0, s1),
			"s1": clampf(float(best_opening["s1"]), s0, s1),
			"y0": clampf(float(best_opening["y0"]), y0, y1),
			"y1": clampf(float(best_opening["y1"]), y0, y1),
			"depth": float(best_opening.get("depth", 0.45)),
			"close_left": absf(s0 - float(best_opening["s0"])) <= 0.000001,
			"close_right": absf(s1 - float(best_opening["s1"])) <= 0.000001,
		}
	return panel

static func _opening_kind(opening: Dictionary) -> PanelKind:
	match String(opening.get("kind", "window")):
		"passage":
			return PanelKind.PASSAGE
		"door":
			return PanelKind.DOOR
		"window":
			return PanelKind.WINDOW
	return PanelKind.SOLID

static func _kind_priority(kind: PanelKind) -> int:
	match kind:
		PanelKind.PASSAGE:
			return 3
		PanelKind.DOOR:
			return 2
		PanelKind.WINDOW:
			return 1
	return 0
