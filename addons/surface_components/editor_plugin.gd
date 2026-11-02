@tool
extends EditorPlugin

const ComponentCatalog = preload("res://scripts/component_catalog.gd")
const ComponentDefinition = preload("res://scripts/component_definition.gd")
const FusedWall = preload("res://scripts/fused_wall.gd")
const SurfaceComponent = preload("res://scripts/surface_component.gd")
const OverlapSolver = preload("res://scripts/overlap_solver.gd")
const Dock = preload("res://addons/surface_components/dock.gd")

var catalog := PCGComponentCatalog.new()
var dock: VBoxContainer
var drag_id: StringName = &""
var ghost: Node3D
var ghost_host: PCGFusedWall
var ghost_anchor := Vector2.ZERO
var ghost_valid := false
var selected: PCGSurfaceComponent
var current_camera: Camera3D
var dragging_component := false
var dragging_handle := ""
var handle_start_mouse := Vector2.ZERO
var handle_start_angle := 0.0
var handle_start_scale := 1.0
# v0.14 编辑命令：所有组件创建/删除/参数编辑经 PCGEditCommandHistory 提交，
# do/undo/redo 共用 _apply_edit_command 补丁入口；拖动按会话 merge_key 合并。
var command_history: PCGEditCommandHistory
var command_targets: Dictionary = {}  # StringName -> PCGSurfaceComponent（会话内 target 解析）
var drag_command_target: StringName = &""
var drag_merge_seq: int = 0

func _ready() -> void:
	catalog.load_from("res://assets/components")
	dock = Dock.new()
	dock.name = "SurfaceComponents"
	dock.setup(self, catalog.definitions)
	EditorInterface.get_inspector().add_child(dock)
	dock.show()
	command_history = PCGEditCommandHistory.new(get_undo_redo(), _apply_edit_command)
	EditorInterface.get_selection().selection_changed.connect(_on_editor_selection_changed)

func _exit_tree() -> void:
	_cancel_ghost()
	if is_instance_valid(dock):
		dock.queue_free()
	EditorInterface.get_selection().selection_changed.disconnect(_on_editor_selection_changed)

func _handles(object: Object) -> bool:
	return object is Node3D

func create_host(kind: int) -> void:
	var root := EditorInterface.get_edited_scene_root()
	if root == null:
		return
	var host := FusedWall.new()
	host.surface_kind = kind
	host.display_name = ["平面主体墙", "圆柱主体", "半球圆柱主体"][kind]
	host.position = Vector3(0.0, 2.5, 0.0) if kind == 0 else Vector3(3.5, 1.9, -0.4)
	var undo := get_undo_redo()
	undo.create_action("创建附着主体")
	undo.add_do_method(self, "_add_host", host, root)
	undo.add_undo_method(self, "_detach_node", host)
	undo.commit_action()
	_select_node(host)

func _add_host(host: PCGFusedWall, root: Node) -> void:
	root.add_child(host)
	host.owner = root

func begin_component_drag(id: StringName) -> void:
	var root := EditorInterface.get_edited_scene_root()
	if root == null:
		return
	_cancel_ghost()
	drag_id = id
	ghost = SurfaceComponent.make_preview(catalog.get_definition(id))
	root.add_child(ghost)
	ghost_valid = false

func finish_component_drag() -> void:
	if not drag_id.is_empty():
		_finish_ghost()

func _forward_3d_gui_input(camera: Camera3D, event: InputEvent) -> int:
	current_camera = camera
	if not drag_id.is_empty():
		if event is InputEventMouseMotion:
			_update_ghost(camera, event.position)
			return AFTER_GUI_INPUT_STOP
		if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT and not event.pressed:
			_finish_ghost()
			return AFTER_GUI_INPUT_STOP
		if event is InputEventKey and event.pressed and event.keycode == KEY_ESCAPE:
			_cancel_ghost()
			return AFTER_GUI_INPUT_STOP
	if dragging_component or not dragging_handle.is_empty():
		if event is InputEventMouseMotion:
			if not dragging_handle.is_empty():
				_drag_handle(event.position)
			else:
				_drag_component(event.position)
			return AFTER_GUI_INPUT_STOP
		if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT and not event.pressed:
			if selected != null:
				selected.flush_transition_csg()
			dragging_component = false
			dragging_handle = ""
			return AFTER_GUI_INPUT_STOP
	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT and event.pressed:
		if selected != null:
			var handle := _pick_handle(camera, event.position)
			if not handle.is_empty():
				dragging_handle = handle
				handle_start_mouse = event.position
				handle_start_angle = selected.attachment_angle_degrees
				handle_start_scale = selected.current_scale
				drag_command_target = _register_command_target(selected)
				drag_merge_seq += 1
				selected.set_transition_deferred(true)
				return AFTER_GUI_INPUT_STOP
		var component := _pick_component(camera, event.position)
		if component != null:
			_select_node(component)
			dragging_component = true
			drag_command_target = _register_command_target(component)
			drag_merge_seq += 1
			component.set_transition_deferred(true)
			return AFTER_GUI_INPUT_STOP
	return AFTER_GUI_INPUT_PASS

func _update_ghost(camera: Camera3D, screen_position: Vector2) -> void:
	if ghost == null:
		return
	var definition := catalog.get_definition(drag_id)
	var origin := camera.project_ray_origin(screen_position)
	var direction := camera.project_ray_normal(screen_position)
	var nearest := INF
	ghost_valid = false
	ghost_host = null
	for host in _hosts():
		var hit := host.ray_anchor(origin, direction)
		if hit.is_empty():
			continue
		var distance := camera.global_position.distance_to(hit["position"])
		if distance < nearest:
			nearest = distance
			ghost_host = host
			ghost_anchor = hit["anchor"]
			ghost_valid = true
	if ghost_valid:
		ghost_anchor = ghost_host.clamp_anchor(ghost_anchor, definition)
		var tilt := Transform3D(Basis(Vector3.RIGHT, deg_to_rad(definition.attachment_angle_degrees)), Vector3.ZERO)
		ghost.global_transform = ghost_host.surface_transform(ghost_anchor) * tilt
	else:
		var plane := Plane(-camera.global_basis.z.normalized(), camera.global_position + camera.global_basis.z * 4.0)
		var point: Variant = plane.intersects_ray(origin, direction)
		if point != null:
			ghost.global_transform = Transform3D(camera.global_basis, point)
	for host in _hosts():
		host.set_highlight(ghost_valid and host == ghost_host)

func _finish_ghost() -> void:
	if ghost_valid and ghost_host != null:
		create_component(drag_id, ghost_host, ghost_anchor)
	_cancel_ghost()

func _cancel_ghost() -> void:
	drag_id = &""
	ghost_valid = false
	ghost_host = null
	if ghost != null:
		ghost.get_parent().remove_child(ghost)
		ghost.queue_free()
		ghost = null
	for host in _hosts():
		host.set_highlight(false)

func create_component(id: StringName, host: PCGFusedWall, anchor: Vector2) -> void:
	var root := EditorInterface.get_edited_scene_root()
	var definition := catalog.get_definition(id)
	if root == null or definition == null:
		return
	var component := SurfaceComponent.new()
	var command := PCGEditCommand.new()
	command.command_id = &"放置表面组件"
	command.target_id = _register_command_target(component)
	command.scope = {"op": &"create", "definition_id": String(id), "host_path": str(host.get_path())}
	command.before = {}
	command.after = {"anchor": host.clamp_anchor(anchor, definition)}
	command.timestamp_ms = Time.get_ticks_msec()
	command_history.submit(command)
	_select_node(component)

func _register_command_target(component: PCGSurfaceComponent) -> StringName:
	for id in command_targets:
		if command_targets[id] == component:
			return id
	var target_id := StringName("surface_component_%d" % component.get_instance_id())
	command_targets[target_id] = component
	return target_id

func _component_param_patch(component: PCGSurfaceComponent) -> Dictionary:
	return {
		"anchor": component.anchor,
		"attachment_angle_degrees": component.attachment_angle_degrees,
		"user_scale": component.user_scale,
		"transition_enabled": component.transition_enabled,
		"transition_thickness": component.transition_thickness,
		"transition_curvature": component.transition_curvature,
		"transition_density": component.transition_density,
		"transition_lod": component.transition_lod,
	}

# 所有命令 do/undo/redo 共用的补丁应用入口。
func _apply_edit_command(command: PCGEditCommand, use_after: bool) -> void:
	var component: PCGSurfaceComponent = command_targets.get(command.target_id)
	if component == null or not is_instance_valid(component):
		push_warning("PCGEditCommand 目标缺失: %s" % command.target_id)
		return
	var op := StringName(command.scope.get("op", &"param"))
	if op == &"create" or op == &"delete":
		var attach := (op == &"create") == use_after
		if attach:
			_restore_component(component, command, command.after if use_after else command.before)
		else:
			_detach_component(component)
		return
	_apply_param_patch(component, command.after if use_after else command.before)

func _restore_component(component: PCGSurfaceComponent, command: PCGEditCommand, patch: Dictionary) -> void:
	var root := EditorInterface.get_edited_scene_root()
	if root == null:
		return
	if component.definition == null:
		var definition := catalog.get_definition(StringName(command.scope.get("definition_id", "")))
		var host: Node = root.get_node_or_null(NodePath(command.scope.get("host_path", "")))
		if definition == null or host == null:
			push_warning("无法恢复组件：定义或宿主缺失")
			return
		component.configure(definition, host)
	if component.get_parent() == null:
		root.add_child(component)
		component.owner = root
	component.wall.register_component(component)
	if patch.is_empty():
		component.update_transform()
		_solve_neighborhood(component)
	else:
		_apply_param_patch(component, patch)

func _apply_param_patch(component: PCGSurfaceComponent, patch: Dictionary) -> void:
	if patch.is_empty() or component.definition == null:
		return
	var needs_transform_update := false
	for key in patch:
		match String(key):
			"anchor":
				var value: Array = patch[key]
				component.anchor = Vector2(float(value[0]), float(value[1]))
				needs_transform_update = true
			"attachment_angle_degrees":
				component.attachment_angle_degrees = float(patch[key])
				needs_transform_update = true
			"user_scale":
				component.set_user_scale(float(patch[key]))
			"transition_enabled":
				component.set_transition_enabled(bool(patch[key]))
			"transition_thickness":
				component.transition_thickness = float(patch[key])
				needs_transform_update = true
			"transition_curvature":
				component.transition_curvature = float(patch[key])
				needs_transform_update = true
			"transition_density":
				component.transition_density = float(patch[key])
				needs_transform_update = true
			"transition_lod":
				component.transition_lod = int(patch[key])
				needs_transform_update = true
	if needs_transform_update:
		component.update_transform()
	if patch.has("anchor") or patch.has("user_scale"):
		_solve_neighborhood(component)

func _submit_param_command(command_id: StringName, patch: Dictionary, merge_key: StringName, component: PCGSurfaceComponent) -> void:
	var command := PCGEditCommand.new()
	command.command_id = command_id
	command.target_id = _register_command_target(component)
	command.scope = {"op": &"param"}
	command.before = _component_param_patch(component)
	command.after = patch
	command.merge_key = merge_key
	command.timestamp_ms = Time.get_ticks_msec()
	command_history.submit(command)

func _detach_component(component: PCGSurfaceComponent) -> void:
	component.wall.unregister_component(component)
	_detach_node(component)

func _detach_node(node: Node) -> void:
	if node.get_parent() != null:
		node.get_parent().remove_child(node)

func _drag_component(screen_position: Vector2) -> void:
	if selected == null:
		return
	var camera := current_camera
	var hit: Dictionary = selected.wall.ray_anchor(
		camera.project_ray_origin(screen_position),
		camera.project_ray_normal(screen_position)
	)
	if hit.is_empty():
		return
	var next_anchor: Vector2 = selected.wall.clamp_anchor(hit["anchor"], selected.definition)
	_submit_param_command(&"拖动表面组件", {"anchor": next_anchor},
		StringName("drag_move:%s:%d" % [drag_command_target, drag_merge_seq]), selected)

func _drag_handle(screen_position: Vector2) -> void:
	if selected == null:
		return
	var delta := screen_position - handle_start_mouse
	var merge_key := StringName("drag_handle:%s:%s:%d" % [dragging_handle, drag_command_target, drag_merge_seq])
	if dragging_handle == "angle":
		_submit_param_command(&"调整法线倾角",
			{"attachment_angle_degrees": clampf(handle_start_angle - delta.y * 0.4, -90.0, 90.0)},
			merge_key, selected)
	elif dragging_handle == "scale":
		selected.neighborhood_scale = 1.0
		_submit_param_command(&"调整组件缩放",
			{"user_scale": handle_start_scale + delta.x * 0.005},
			merge_key, selected)

func _pick_component(camera: Camera3D, screen_position: Vector2) -> PCGSurfaceComponent:
	var hit := _ray_areas(camera, screen_position, 2)
	if hit.is_empty():
		return null
	return hit["collider"].get_meta("surface_component") as PCGSurfaceComponent

func _pick_handle(camera: Camera3D, screen_position: Vector2) -> String:
	var hit := _ray_areas(camera, screen_position, 4)
	if hit.is_empty():
		return ""
	return hit["collider"].get_meta("attachment_handle", "") as String

func _ray_areas(camera: Camera3D, screen_position: Vector2, mask: int) -> Dictionary:
	var origin := camera.project_ray_origin(screen_position)
	var direction := camera.project_ray_normal(screen_position)
	var query := PhysicsRayQueryParameters3D.create(origin, origin + direction * 100.0)
	query.collide_with_areas = true
	query.collide_with_bodies = false
	query.collision_mask = mask
	return EditorInterface.get_edited_scene_root().get_world_3d().direct_space_state.intersect_ray(query)

func _on_editor_selection_changed() -> void:
	var nodes := EditorInterface.get_selection().get_selected_nodes()
	var next: PCGSurfaceComponent = null
	for node in nodes:
		if node is PCGSurfaceComponent:
			next = node
			break
	if selected != null and selected != next and is_instance_valid(selected):
		selected.set_selected(false)
	selected = next
	if selected != null:
		selected.set_selected(true)
	dock.set_selected(selected)

func _select_node(node: Node) -> void:
	EditorInterface.get_selection().clear()
	EditorInterface.get_selection().add_node(node)

func set_attachment_angle(value: float) -> void:
	if selected != null:
		_submit_param_command(&"设置法线倾角", {"attachment_angle_degrees": value}, &"", selected)

func set_user_scale(value: float) -> void:
	if selected != null:
		_submit_param_command(&"设置组件缩放", {"user_scale": value}, &"", selected)

func set_transition_enabled(value: bool) -> void:
	if selected != null:
		_submit_param_command(&"设置过渡开关", {"transition_enabled": value}, &"", selected)

func set_transition_thickness(value: float) -> void:
	if selected != null:
		_submit_param_command(&"设置过渡厚度", {"transition_thickness": value}, &"", selected)

func set_transition_curvature(value: float) -> void:
	if selected != null:
		_submit_param_command(&"设置过渡弧度", {"transition_curvature": value}, &"", selected)

func set_transition_density(index: int) -> void:
	if selected != null:
		_submit_param_command(&"设置过渡精度", {"transition_density": [0.25, 0.5, 1.0, 2.0][index]}, &"", selected)

func set_transition_lod(index: int) -> void:
	if selected != null:
		_submit_param_command(&"设置过渡 LOD", {"transition_lod": index}, &"", selected)

func set_deferred_fusion(value: bool) -> void:
	for host in _hosts():
		host.set_preview_mode(value)

func merge_selected() -> void:
	if selected != null:
		var host := selected.wall
		host.preview_mode = false
		host.merge_component(selected)
		selected.set_direct_preview(false)
		dock.set_selected(selected)

func merge_all() -> void:
	for host in _hosts():
		host.set_preview_mode(false)
		for component in host.components:
			component.set_direct_preview(false)
			component.flush_transition_csg()

func delete_selected() -> void:
	if selected == null:
		return
	var component := selected
	var command := PCGEditCommand.new()
	command.command_id = &"删除表面组件"
	command.target_id = _register_command_target(component)
	command.scope = {"op": &"delete"}
	command.before = _component_param_patch(component)
	command.after = {}
	command.timestamp_ms = Time.get_ticks_msec()
	command_history.submit(command)
	selected = null
	dock.set_selected(null)

func _solve_neighborhood(dragged: PCGSurfaceComponent) -> void:
	var components: Array = []
	for host in _hosts():
		components.append_array(host.components)
	var scales := OverlapSolver.solve(components, dragged, selected)
	for component in components:
		component.apply_scale(scales[component.get_instance_id()])
		if component == selected:
			component.set_selected(true)
	dock.set_selected(selected)

func _hosts() -> Array[PCGFusedWall]:
	var result: Array[PCGFusedWall] = []
	var root := EditorInterface.get_edited_scene_root()
	if root != null:
		_collect_hosts(root, result)
	return result

func _collect_hosts(node: Node, result: Array[PCGFusedWall]) -> void:
	if node is PCGFusedWall:
		result.append(node)
	for child in node.get_children():
		_collect_hosts(child, result)
