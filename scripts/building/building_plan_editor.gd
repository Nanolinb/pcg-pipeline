@tool
class_name PCGBuildingPlanEditor
extends Control

signal footprint_selected(id: StringName, additive: bool)
signal vertex_drag_started(id: StringName)
signal footprint_edited(id: StringName)
signal footprint_move_started(id: StringName)
signal footprint_moved(id: StringName, delta: Vector2)
signal footprint_move_finished(id: StringName)
signal vertex_drag_finished(id: StringName)
signal connector_placed(building_id: StringName, edge_index: int, edge_t: float)
signal connector_selected(connector_id: StringName)
signal bridge_node_selected(bridge_id: StringName, node_index: int)
signal bridge_node_moved(bridge_id: StringName, node_index: int, position: Vector3)
signal bridge_node_drag_finished(bridge_id: StringName)
signal bridge_node_insert_requested(bridge_id: StringName, position: Vector3)
signal bridge_node_remove_requested(bridge_id: StringName, node_index: int)
signal bridge_handle_moved(bridge_id: StringName, node_index: int, kind: StringName, offset: Vector3)
signal bridge_section_started(bridge_id: StringName)
signal bridge_section_changed(bridge_id: StringName, kind: StringName, value: float)
signal bridge_section_finished(bridge_id: StringName)
signal zoom_changed(value: float)

enum InteractionMode { FOOTPRINT, CONNECTOR, BRIDGE_NODE, BRIDGE_ADD, BRIDGE_REMOVE }

const NODE_PICK_RADIUS := 12.0
const EDGE_PICK_RADIUS := 12.0

var plan: PCGBuildingPlan
var selected_id: StringName = &""
var selected_ids: Array[StringName] = []
var interaction_mode: int = InteractionMode.FOOTPRINT
var selected_bridge_id: StringName = &""
var selected_connector_id: StringName = &""
var selected_node_index: int = -1
var _drag_id: StringName = &""
var _drag_vertex: int = -1
var _drag_bridge: StringName = &""
var _drag_node: int = -1
var _drag_handle: StringName = &""
var _drag_section_kind: StringName = &""
var _section_start := Vector2.ZERO
var _section_drag_accum := 0.0
var _drag_building := false
var _last_building_world := Vector2.ZERO
var _pan_offset := Vector2.ZERO
var _panning := false
var _last_pan_position := Vector2.ZERO
var _zoom := 1.0

func _init() -> void:
	custom_minimum_size = Vector2(300.0, 290.0)
	mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	clip_contents = true

func set_plan(value: PCGBuildingPlan) -> void:
	plan = value
	queue_redraw()

func select_footprint(id: StringName) -> void:
	selected_id = id
	selected_ids.assign([id] if not id.is_empty() else [])
	queue_redraw()

func set_selection(ids: Array[StringName], primary: StringName) -> void:
	selected_ids = ids.duplicate()
	selected_id = primary
	queue_redraw()

func set_interaction_mode(mode: int) -> void:
	interaction_mode = mode
	if mode != InteractionMode.BRIDGE_NODE and mode != InteractionMode.BRIDGE_ADD \
			and mode != InteractionMode.BRIDGE_REMOVE:
		selected_bridge_id = &""
		selected_node_index = -1
	queue_redraw()

func world_to_screen(point: Vector2) -> Vector2:
	return size * 0.5 + _pan_offset + point * _pixels_per_meter()

func screen_to_world(point: Vector2) -> Vector2:
	return (point - size * 0.5 - _pan_offset) / _pixels_per_meter()

func zoom_at(position: Vector2, factor: float) -> void:
	var anchor := screen_to_world(position)
	_zoom = clampf(_zoom * factor, 0.25, 8.0)
	_pan_offset = position - size * 0.5 - anchor * _pixels_per_meter()
	queue_redraw()
	zoom_changed.emit(_zoom)

func fit_to_content() -> void:
	if plan == null:
		return
	var points := PackedVector2Array()
	for footprint in plan.footprints:
		if footprint != null:
			points.append_array(footprint.normalized_polygon())
	for connector in plan.connectors:
		if connector == null:
			continue
		var footprint := plan.get_footprint(connector.building_id)
		if footprint != null:
			var anchor: Vector3 = connector.anchor(footprint)["position"]
			points.append(Vector2(anchor.x, anchor.z))
	for bridge in plan.skybridges:
		if bridge == null:
			continue
		for point in bridge.node_positions():
			points.append(Vector2(point.x, point.z))
	if points.is_empty():
		_zoom = 1.0
		_pan_offset = Vector2.ZERO
	else:
		var bounds := Rect2(points[0], Vector2.ZERO)
		for point in points:
			bounds = bounds.expand(point)
		var base := maxf(1.0, minf(size.x, size.y) / 14.0)
		var fit := minf(maxf(size.x - 36.0, 32.0) / maxf(bounds.size.x, 1.0),
			maxf(size.y - 36.0, 32.0) / maxf(bounds.size.y, 1.0))
		_zoom = clampf(fit / base, 0.25, 8.0)
		_pan_offset = -bounds.get_center() * _pixels_per_meter()
	queue_redraw()
	zoom_changed.emit(_zoom)

func _pixels_per_meter() -> float:
	return maxf(1.0, minf(size.x, size.y) / 14.0) * _zoom

func _gui_input(event: InputEvent) -> void:
	if plan == null:
		return
	if event is InputEventMouseButton:
		if event.pressed and event.button_index in [MOUSE_BUTTON_WHEEL_UP, MOUSE_BUTTON_WHEEL_DOWN]:
			zoom_at(event.position, 1.2 if event.button_index == MOUSE_BUTTON_WHEEL_UP else 1.0 / 1.2)
			accept_event()
			return
		if event.pressed:
			if event.button_index in [MOUSE_BUTTON_RIGHT, MOUSE_BUTTON_MIDDLE]:
				_panning = true
				_last_pan_position = event.position
			elif event.button_index == MOUSE_BUTTON_LEFT:
				match interaction_mode:
					InteractionMode.CONNECTOR:
						_handle_connector_click(event.position)
					InteractionMode.BRIDGE_NODE:
						_handle_node_click(event.position)
					InteractionMode.BRIDGE_ADD:
						_handle_add_click(event.position)
					InteractionMode.BRIDGE_REMOVE:
						_handle_remove_click(event.position)
					_:
						_handle_footprint_click(event.position, event.shift_pressed)
				_last_pan_position = event.position
				queue_redraw()
		else:
			if event.button_index == MOUSE_BUTTON_LEFT:
				if _drag_section_kind != &"":
					bridge_section_finished.emit(_drag_bridge)
					_drag_bridge = &""
					_drag_section_kind = &""
				if _drag_vertex >= 0:
					vertex_drag_finished.emit(_drag_id)
					_drag_id = &""
					_drag_vertex = -1
				if _drag_node >= 0:
					bridge_node_drag_finished.emit(_drag_bridge)
					_drag_bridge = &""
					_drag_node = -1
					_drag_handle = &""
				if _drag_building:
					footprint_move_finished.emit(_drag_id)
					_drag_building = false
					_drag_id = &""
			_panning = false
		accept_event()
	elif event is InputEventMouseMotion:
		if _drag_section_kind != &"":
			var section_bridge := plan.get_skybridge(_drag_bridge)
			if section_bridge != null:
				if _drag_section_kind == &"width":
					var section := _section_mid_data(section_bridge)
					if not section.is_empty():
						var point := screen_to_world(event.position)
						var world := Vector3(point.x, 0.0, point.y)
						var center: Vector3 = section["position"]
						var right: Vector3 = section["right"]
						var half := (world - Vector3(center.x, 0.0, center.z)).dot(
							Vector3(right.x, 0.0, right.z))
						var width := snappedf(clampf(absf(half) * 2.0, 0.8, 8.0), 0.1)
						bridge_section_changed.emit(_drag_bridge, &"width", width)
				else:
					# 高度在顶视图中用屏幕纵向拖拽：上拉加高、下拉降低。
					_section_drag_accum += -event.relative.y / maxf(_pixels_per_meter(), 1.0) * 0.75
					var height := snappedf(
						clampf(section_bridge.height + _section_drag_accum, 1.6, 8.0), 0.05)
					_section_drag_accum = height - section_bridge.height
					bridge_section_changed.emit(_drag_bridge, &"height", height)
				queue_redraw()
		elif _drag_vertex >= 0:
			var footprint := plan.get_footprint(_drag_id)
			if footprint != null:
				var point := screen_to_world(event.position)
				point.x = snappedf(point.x, 0.25)
				point.y = snappedf(point.y, 0.25)
				footprint.polygon[_drag_vertex] = point
				footprint_edited.emit(_drag_id)
				queue_redraw()
		elif _drag_node >= 0:
			var bridge := plan.get_skybridge(_drag_bridge)
			if bridge != null:
				var point := screen_to_world(event.position)
				var snapped := Vector3(snappedf(point.x, 0.25), 0.0, snappedf(point.y, 0.25))
				if _drag_handle != &"":
					var node_pos: Vector3 = bridge.node_positions()[_drag_node]
					snapped.y = bridge.node_handle(_drag_node, _drag_handle).y
					bridge_handle_moved.emit(_drag_bridge, _drag_node, _drag_handle,
						snapped - Vector3(node_pos.x, 0.0, node_pos.z))
				else:
					snapped.y = bridge.node_positions()[_drag_node].y
					bridge_node_moved.emit(_drag_bridge, _drag_node, snapped)
				queue_redraw()
		elif _drag_building:
			var world := screen_to_world(event.position)
			var delta := (world - _last_building_world).snapped(Vector2.ONE * 0.25)
			if not delta.is_zero_approx():
				footprint_moved.emit(_drag_id, delta)
				_last_building_world += delta
				queue_redraw()
		elif _panning:
			_pan_offset += event.position - _last_pan_position
			_last_pan_position = event.position
			queue_redraw()
		accept_event()

func _handle_footprint_click(position: Vector2, additive: bool = false) -> void:
	var vertex_hit := _pick_vertex(position)
	if not vertex_hit.is_empty():
		selected_id = vertex_hit["id"]
		_drag_id = selected_id
		_drag_vertex = vertex_hit["index"]
		footprint_selected.emit(selected_id, false)
		vertex_drag_started.emit(selected_id)
	else:
		var footprint := _pick_footprint(screen_to_world(position))
		if footprint != null:
			selected_id = footprint.id
			_drag_id = selected_id
			_drag_building = true
			_last_building_world = screen_to_world(position)
			footprint_selected.emit(selected_id, additive)
			footprint_move_started.emit(selected_id)
		else:
			_panning = true

func _handle_connector_click(position: Vector2) -> void:
	var connector_hit := _pick_connector(position)
	if not connector_hit.is_empty():
		selected_connector_id = connector_hit["id"]
		connector_selected.emit(selected_connector_id)
		queue_redraw()
		return
	selected_connector_id = &""
	var edge_hit := _pick_edge(position)
	if not edge_hit.is_empty():
		connector_placed.emit(edge_hit["id"], edge_hit["edge_index"], edge_hit["edge_t"])
	else:
		_panning = true

func _pick_connector(position: Vector2) -> Dictionary:
	for connector in plan.connectors:
		if connector == null:
			continue
		var footprint := plan.get_footprint(connector.building_id)
		if footprint == null:
			continue
		var polygon := footprint.normalized_polygon()
		if polygon.is_empty():
			continue
		var index := clampi(connector.edge_index, 0, polygon.size() - 1)
		var point := polygon[index].lerp(polygon[(index + 1) % polygon.size()], connector.edge_t)
		if world_to_screen(point).distance_to(position) <= NODE_PICK_RADIUS:
			return {"id": connector.id}
	return {}

func _handle_node_click(position: Vector2) -> void:
	var section_hit := _pick_section_grip(position)
	if not section_hit.is_empty():
		selected_bridge_id = section_hit["bridge"]
		_drag_bridge = selected_bridge_id
		_drag_section_kind = section_hit["kind"]
		_section_start = position
		_section_drag_accum = 0.0
		bridge_section_started.emit(selected_bridge_id)
		queue_redraw()
		return
	var node_hit := _pick_bridge_node(position)
	if not node_hit.is_empty():
		selected_bridge_id = node_hit["bridge"]
		selected_node_index = node_hit["index"]
		_drag_bridge = selected_bridge_id
		_drag_node = selected_node_index
		_drag_handle = node_hit.get("handle", &"")
		bridge_node_selected.emit(selected_bridge_id, selected_node_index)
	else:
		_panning = true

# 桥中点横截面手柄：宽度端点（沿桥横向）与高度 H 手柄（屏幕纵向拖拽）。
func _pick_section_grip(position: Vector2) -> Dictionary:
	for bridge in plan.skybridges:
		if bridge == null or bridge.nodes.size() < 2:
			continue
		var section := _section_mid_data(bridge)
		if section.is_empty():
			continue
		var center: Vector3 = section["position"]
		var center_screen := world_to_screen(Vector2(center.x, center.z))
		for side in [-1.0, 1.0]:
			var grip: Vector3 = center + section["right"] * (bridge.width * 0.5) * side
			var grip_screen := world_to_screen(Vector2(grip.x, grip.z))
			if grip_screen.distance_to(position) <= NODE_PICK_RADIUS:
				return {"bridge": bridge.id, "kind": &"width"}
		var height_screen := center_screen + Vector2(16.0, -16.0)
		if height_screen.distance_to(position) <= NODE_PICK_RADIUS:
			return {"bridge": bridge.id, "kind": &"height"}
	return {}

# 截面中点数据：按弧长取路径中点与局部坐标架。
func _section_mid_data(bridge: PCGSkybridgeDefinition) -> Dictionary:
	var path := bridge.sampled_path(8)
	if path.size() < 2:
		return {}
	var total := 0.0
	var distances: Array[float] = [0.0]
	for index in range(1, path.size()):
		total += path[index].distance_to(path[index - 1])
		distances.append(total)
	var half := total * 0.5
	for index in range(1, path.size()):
		if distances[index] >= half or index == path.size() - 1:
			var segment := distances[index] - distances[index - 1]
			var u := 0.0 if segment <= 0.0001 else clampf((half - distances[index - 1]) / segment, 0.0, 1.0)
			var position := path[index - 1].lerp(path[index], u)
			var forward := path[index] - path[index - 1]
			if forward.length() < 0.0001:
				forward = Vector3.FORWARD
			forward = forward.normalized()
			var right := Vector3.UP.cross(forward).normalized()
			return {"position": position, "right": right, "up": forward.cross(right).normalized()}
	return {}

func _handle_add_click(position: Vector2) -> void:
	var curve_hit := _pick_curve_point(position)
	if not curve_hit.is_empty():
		selected_bridge_id = curve_hit["bridge"]
		bridge_node_insert_requested.emit(curve_hit["bridge"], curve_hit["position"])
		queue_redraw()
	else:
		_panning = true

func _handle_remove_click(position: Vector2) -> void:
	var node_hit := _pick_bridge_node(position)
	if not node_hit.is_empty() and node_hit.get("handle", &"") == &"":
		selected_bridge_id = node_hit["bridge"]
		selected_node_index = node_hit["index"]
		bridge_node_remove_requested.emit(node_hit["bridge"], node_hit["index"])
		queue_redraw()
	else:
		_panning = true

# 距离点击位置最近的桥曲线采样点（用于增加节点）。
func _pick_curve_point(position: Vector2) -> Dictionary:
	var best := {}
	var best_distance := NODE_PICK_RADIUS + 3.0
	for bridge in plan.skybridges:
		if bridge == null:
			continue
		for point in bridge.sampled_path(8):
			var distance := world_to_screen(Vector2(point.x, point.z)).distance_to(position)
			if distance <= best_distance:
				best_distance = distance
				best = {"bridge": bridge.id, "position": point}
	return best

func _pick_vertex(position: Vector2) -> Dictionary:
	for footprint in plan.footprints:
		if footprint == null:
			continue
		for index in footprint.polygon.size():
			if world_to_screen(footprint.polygon[index]).distance_to(position) <= 10.0:
				return {"id": footprint.id, "index": index}
	return {}

func _pick_footprint(point: Vector2) -> PCGBuildingFootprint:
	for index in range(plan.footprints.size() - 1, -1, -1):
		var footprint := plan.footprints[index]
		if footprint != null and Geometry2D.is_point_in_polygon(point, footprint.normalized_polygon()):
			return footprint
	return null

func _pick_edge(position: Vector2) -> Dictionary:
	var best := {}
	var best_distance := EDGE_PICK_RADIUS
	for footprint in plan.footprints:
		if footprint == null:
			continue
		var polygon := footprint.normalized_polygon()
		if polygon.size() < 3:
			continue
		for edge_index in polygon.size():
			var a := polygon[edge_index]
			var b := polygon[(edge_index + 1) % polygon.size()]
			var closest := Geometry2D.get_closest_point_to_segment(screen_to_world(position), a, b)
			var distance := world_to_screen(closest).distance_to(position)
			if distance <= best_distance:
				var length := maxf(a.distance_to(b), 0.001)
				best_distance = distance
				best = {
					"id": footprint.id,
					"edge_index": edge_index,
					"edge_t": clampf(a.distance_to(closest) / length, 0.02, 0.98),
				}
	return best

func _pick_bridge_node(position: Vector2) -> Dictionary:
	for bridge in plan.skybridges:
		if bridge == null:
			continue
		var positions := bridge.node_positions()
		for index in positions.size():
			var node_screen := world_to_screen(Vector2(positions[index].x, positions[index].z))
			# 手柄优先：命中手柄端点即拖手柄，其次才选中节点本身。
			for kind in [&"in", &"out"]:
				if bridge.has_node_handle(index, kind):
					var handle_pos: Vector3 = positions[index] + bridge.node_handle(index, kind)
					var handle_screen := world_to_screen(Vector2(handle_pos.x, handle_pos.z))
					if handle_screen.distance_to(position) <= NODE_PICK_RADIUS - 2.0:
						return {"bridge": bridge.id, "index": index, "handle": kind}
			if node_screen.distance_to(position) <= NODE_PICK_RADIUS:
				return {"bridge": bridge.id, "index": index, "handle": &""}
	return {}

func _draw() -> void:
	draw_rect(Rect2(Vector2.ZERO, size), Color("14242b"))
	if plan == null:
		return
	var unit := _pixels_per_meter()
	var origin := size * 0.5 + _pan_offset
	for grid in range(-20, 21):
		var color := Color("2b4149") if grid % 5 != 0 else Color("39535d")
		draw_line(origin + Vector2(grid * unit, -size.y), origin + Vector2(grid * unit, size.y), color, 1.0)
		draw_line(origin + Vector2(-size.x, grid * unit), origin + Vector2(size.x, grid * unit), color, 1.0)
	for footprint in plan.footprints:
		if footprint == null:
			continue
		var polygon := footprint.normalized_polygon()
		if polygon.size() < 3:
			continue
		var points := PackedVector2Array()
		for point in polygon:
			points.append(world_to_screen(point))
		var selected := selected_ids.has(footprint.id)
		var fill := footprint.wall_color.darkened(0.2 if selected else 0.45)
		fill.a = 0.9
		draw_colored_polygon(points, fill)
		var outline := points.duplicate()
		outline.append(points[0])
		draw_polyline(outline, Color("f4c66a") if selected else footprint.wall_color.lightened(0.25), 2.5 if selected else 1.5, true)
		for point in points:
			draw_circle(point, 5.0 if selected else 3.5, Color("ffe29a") if selected else Color("b9d5d8"))
	_draw_connectors()
	_draw_skybridges()

func _draw_connectors() -> void:
	var font := get_theme_default_font()
	for connector in plan.connectors:
		if connector == null:
			continue
		var footprint := plan.get_footprint(connector.building_id)
		if footprint == null:
			continue
		var polygon := footprint.normalized_polygon()
		if polygon.is_empty():
			continue
		var index := clampi(connector.edge_index, 0, polygon.size() - 1)
		var point := polygon[index].lerp(polygon[(index + 1) % polygon.size()], connector.edge_t)
		var screen := world_to_screen(point)
		var is_selected := connector.id == selected_connector_id
		var radius := 9.0 if is_selected else 7.0
		var marker := PackedVector2Array([
			screen + Vector2(0, -radius), screen + Vector2(radius, 0),
			screen + Vector2(0, radius), screen + Vector2(-radius, 0)])
		draw_colored_polygon(marker, Color("ffd166") if is_selected else Color("6fd3c7"))
		draw_polyline(marker + PackedVector2Array([marker[0]]), Color("123c38"), 1.0)
		draw_string(font, screen + Vector2(9, -6), "F%d·%s" % [connector.floor, connector.id],
			HORIZONTAL_ALIGNMENT_LEFT, -1.0, 11, Color("ffe3a3") if is_selected else Color("9fe8df"))

func _draw_skybridges() -> void:
	var font := get_theme_default_font()
	for bridge in plan.skybridges:
		if bridge == null:
			continue
		var selected := bridge.id == selected_bridge_id
		var color := Color("f4a66a") if selected else Color("8fb7c9")
		var path := bridge.sampled_path(8)
		if path.size() >= 2:
			var line := PackedVector2Array()
			for point in path:
				line.append(world_to_screen(Vector2(point.x, point.z)))
			draw_polyline(line, color.darkened(0.25), 4.5 if selected else 3.0, true)
			draw_polyline(line, color, 1.5 if selected else 1.0, true)
		var positions := bridge.node_positions()
		for index in positions.size():
			var screen := world_to_screen(Vector2(positions[index].x, positions[index].z))
			# 贝塞尔手柄：节点与手柄端点连线 + 端点小圆点。
			for kind in [&"in", &"out"]:
				if bridge.has_node_handle(index, kind):
					var handle_pos: Vector3 = positions[index] + bridge.node_handle(index, kind)
					var handle_screen := world_to_screen(Vector2(handle_pos.x, handle_pos.z))
					var active := selected and index == selected_node_index
					draw_line(screen, handle_screen,
						Color("ffd166") if active else color.darkened(0.1), 1.5 if active else 1.0)
					draw_circle(handle_screen, 4.5 if active else 3.2,
						Color("ffe3a3") if active else Color("e8c47f"))
			var radius := 6.5 if selected and index == selected_node_index else 4.5
			var rect := Rect2(screen - Vector2(radius, radius), Vector2(radius * 2.0, radius * 2.0))
			draw_rect(rect, Color("ffd9a0") if selected and index == selected_node_index else color)
			draw_rect(rect, Color("1d2f37"), false, 1.0)
			draw_string(font, screen + Vector2(8, -8),
				"%.1fm" % positions[index].y, HORIZONTAL_ALIGNMENT_LEFT, -1.0, 10,
				Color("cfe3ea"))
		if not positions.is_empty():
			var label_at := world_to_screen(Vector2(positions[0].x, positions[0].z))
			draw_string(font, label_at + Vector2(10, 14), String(bridge.id),
				HORIZONTAL_ALIGNMENT_LEFT, -1.0, 11, color.lightened(0.3))
		_draw_section_grips(bridge, selected)
		if absf(bridge.auto_lift) > 0.001:
			var lift_at := world_to_screen(Vector2(positions[0].x, positions[0].z))
			draw_string(font, lift_at + Vector2(10, 26), "自动错开 %+0.2fm" % bridge.auto_lift,
				HORIZONTAL_ALIGNMENT_LEFT, -1.0, 10, Color("e8c47f"))

# 中点横截面手柄：桥面基准线（两端宽度握把）+ 高度 H 握把（屏幕纵向拖动）。
func _draw_section_grips(bridge: PCGSkybridgeDefinition, selected: bool) -> void:
	if bridge.nodes.size() < 2:
		return
	var section := _section_mid_data(bridge)
	if section.is_empty():
		return
	var font := get_theme_default_font()
	var center: Vector3 = section["position"]
	var right: Vector3 = section["right"]
	var center_screen := world_to_screen(Vector2(center.x, center.z))
	var grip_color := Color("6fd3c7") if not selected else Color("9fe8df")
	var left_grip: Vector3 = center - right * (bridge.width * 0.5)
	var right_grip: Vector3 = center + right * (bridge.width * 0.5)
	draw_line(world_to_screen(Vector2(left_grip.x, left_grip.z)),
		world_to_screen(Vector2(right_grip.x, right_grip.z)),
		grip_color.darkened(0.2), 2.0 if selected else 1.5)
	for grip in [left_grip, right_grip]:
		var grip_screen := world_to_screen(Vector2(grip.x, grip.z))
		var rect := Rect2(grip_screen - Vector2(4.5, 4.5), Vector2(9.0, 9.0))
		draw_rect(rect, grip_color)
		draw_rect(rect, Color("123c38"), false, 1.0)
	var height_screen := center_screen + Vector2(16.0, -16.0)
	draw_line(center_screen, height_screen, grip_color.darkened(0.3), 1.0)
	draw_circle(height_screen, 5.5, Color("e8c47f"))
	draw_string(font, height_screen + Vector2(7, -7), "H", HORIZONTAL_ALIGNMENT_LEFT, -1.0, 11,
		Color("ffe3a3"))
