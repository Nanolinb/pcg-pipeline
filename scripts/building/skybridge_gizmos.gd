class_name PCGSkybridgeGizmos
extends Node3D

# 主视图编辑手柄：贴近墙面交接处的横截面框（宽度/高度握把）与各节点的贝塞尔手柄。
# 只负责可视化与拾取/拖拽计算，数据修改与撤销由 workbench 处理。

const PICK_PIXELS := 16.0

var camera: Camera3D
var grips: Array[Dictionary] = []

func rebuild(plan: PCGBuildingPlan) -> void:
	for child in get_children():
		remove_child(child)
		child.free()
	grips.clear()
	if plan == null or camera == null:
		return
	for bridge in plan.skybridges:
		if bridge == null or bridge.nodes.size() < 2:
			continue
		_build_section_gizmo(bridge)
		_build_handle_gizmos(bridge)

# 桥起点附近（贴近墙面交接处）的横截面框。
func _build_section_gizmo(bridge: PCGSkybridgeDefinition) -> void:
	var path := bridge.sampled_path(8)
	if path.size() < 2:
		return
	var start: Vector3 = path[0]
	var forward: Vector3 = path[1] - start
	if forward.length() < 0.0001:
		return
	forward = forward.normalized()
	var right := Vector3.UP.cross(forward).normalized()
	var up := forward.cross(right).normalized()
	var center := start + forward * 0.9
	var half := bridge.width * 0.5
	var left := center - right * half
	var right_side := center + right * half
	var left_top := left + up * bridge.height
	var right_top := right_side + up * bridge.height
	var frame_color := Color("6fd3c7")
	_add_line(left, right_side, frame_color)
	_add_line(left, left_top, frame_color.darkened(0.25))
	_add_line(right_side, right_top, frame_color.darkened(0.25))
	_add_line(left_top, right_top, Color("e8c47f"))
	_add_grip("width", bridge.id, left, {
		"center": center, "right": right, "up": up, "side": -1.0})
	_add_grip("width", bridge.id, right_side, {
		"center": center, "right": right, "up": up, "side": 1.0})
	_add_grip("height", bridge.id, center + up * bridge.height, {
		"center": center, "right": right, "up": up})

# 每个节点的贝塞尔手柄：未显式设置时由 tension 推导对称手柄，拖动手柄后转为显式。
func _build_handle_gizmos(bridge: PCGSkybridgeDefinition) -> void:
	var positions := bridge.node_positions()
	for index in positions.size():
		var position: Vector3 = positions[index]
		var previous: Vector3 = positions[max(index - 1, 0)]
		var next: Vector3 = positions[min(index + 1, positions.size() - 1)]
		var default_offset := (next - previous) * (bridge.node_tension(index) / 3.0)
		for kind in [&"in", &"out"]:
			var offset: Vector3 = default_offset if kind == &"out" else -default_offset
			if bridge.has_node_handle(index, kind):
				offset = bridge.node_handle(index, kind)
			var grip_position := position + offset
			_add_line(position, grip_position, Color("e8c47f").darkened(0.2))
			_add_grip("handle", bridge.id, grip_position, {
				"index": index, "handle": kind, "node": position})

func pick(screen_position: Vector2) -> Dictionary:
	var best := {}
	var best_distance := PICK_PIXELS
	if camera == null:
		return best
	for grip in grips:
		var screen: Vector2 = camera.unproject_position(grip["position"])
		var distance := screen.distance_to(screen_position)
		if distance < best_distance:
			best_distance = distance
			best = grip
	return best

# 拖拽换算：handle 返回 {"offset": Vector3}；width/height 返回对应数值。
func drag_value(grip: Dictionary, screen_position: Vector2) -> Dictionary:
	if camera == null:
		return {}
	var origin := camera.project_ray_origin(screen_position)
	var direction := camera.project_ray_normal(screen_position)
	var meta: Dictionary = grip["meta"]
	var kind: String = grip["kind"]
	if kind == "handle":
		var node: Vector3 = meta["node"]
		var hit: Variant = Plane(Vector3.UP, node.y).intersects_ray(origin, direction)
		if hit != null:
			return {"offset": hit - node}
	elif kind == "width":
		var center: Vector3 = meta["center"]
		var right: Vector3 = meta["right"]
		var hit: Variant = Plane(Vector3.UP, center.y).intersects_ray(origin, direction)
		if hit != null:
			var half: float = (hit - center).dot(right)
			return {"width": snappedf(clampf(absf(half) * 2.0, 0.8, 8.0), 0.1)}
	else:
		var center: Vector3 = meta["center"]
		var right: Vector3 = meta["right"]
		var hit: Variant = Plane(right.normalized(), right.normalized().dot(center)).intersects_ray(
			origin, direction)
		if hit != null:
			return {"height": snappedf(clampf(hit.y - center.y, 1.6, 8.0), 0.05)}
	return {}

func _add_grip(kind: String, bridge_id: StringName, position: Vector3, meta: Dictionary) -> void:
	grips.append({"kind": kind, "bridge_id": bridge_id, "position": position, "meta": meta})
	var mesh := BoxMesh.new()
	mesh.size = Vector3.ONE * (0.18 if kind != "handle" else 0.13)
	var visual := MeshInstance3D.new()
	visual.mesh = mesh
	visual.position = position
	visual.material_override = _grip_material(
		Color("6fd3c7") if kind != "handle" else Color("e8c47f"))
	add_child(visual)

func _add_line(a: Vector3, b: Vector3, color: Color) -> void:
	var mesh := ImmediateMesh.new()
	mesh.surface_begin(Mesh.PRIMITIVE_LINES)
	mesh.surface_add_vertex(a)
	mesh.surface_add_vertex(b)
	mesh.surface_end()
	var visual := MeshInstance3D.new()
	visual.mesh = mesh
	visual.material_override = _grip_material(color)
	add_child(visual)

func _grip_material(color: Color) -> StandardMaterial3D:
	var material := StandardMaterial3D.new()
	material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	material.no_depth_test = true
	material.albedo_color = color
	return material
