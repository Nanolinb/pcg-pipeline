@tool
class_name BuildingPlanSession
extends RefCounted

# 建筑平面编辑会话：持有 plan 状态与统一编辑历史（PCGEditCommandHistory 适配）。
# before/after 补丁与旧工作台 _plan_snapshot 格式兼容；UI/相机/场景同步由
# 工作台经 apply_callback 回调完成，本类不触碰任何节点。

enum Op { PLAN, FOOTPRINT, BRIDGE, TERRAIN }

const OP_KEYS := {
	Op.PLAN: &"plan",
	Op.FOOTPRINT: &"footprint",
	Op.BRIDGE: &"bridge",
	Op.TERRAIN: &"terrain",
}

var plan: PCGBuildingPlan
var history: PCGEditCommandHistory

var _apply_callback: Callable  # func(command: PCGEditCommand, use_after: bool) -> void

func _init(p_plan: PCGBuildingPlan, p_apply_callback: Callable) -> void:
	plan = p_plan
	history = PCGEditCommandHistory.new(UndoRedo.new(), _apply_entry)
	_apply_callback = p_apply_callback

func undo() -> void:
	history.undo()

func redo() -> void:
	history.redo()

func clear_history() -> void:
	history.clear_history()

# 与旧工作台 _plan_snapshot 相同：三类资源各自深拷贝。
func snapshot() -> Dictionary:
	var footprints: Array = []
	for footprint in plan.footprints:
		footprints.append(footprint.duplicate(true) if footprint != null else null)
	var connectors: Array = []
	for connector in plan.connectors:
		connectors.append(connector.duplicate(true) if connector != null else null)
	var skybridges: Array = []
	for bridge in plan.skybridges:
		skybridges.append(bridge.duplicate(true) if bridge != null else null)
	return {
		"footprints": footprints,
		"connectors": connectors,
		"skybridges": skybridges,
	}

# 与旧工作台 _restore_plan 的数据部分相同；选择/UI 同步由回调负责。
func restore(snapshot: Dictionary) -> void:
	plan.footprints.clear()
	for footprint in snapshot["footprints"]:
		plan.footprints.append(footprint.duplicate(true) if footprint != null else null)
	plan.connectors.clear()
	for connector in snapshot["connectors"]:
		plan.connectors.append(connector.duplicate(true) if connector != null else null)
	plan.skybridges.clear()
	for bridge in snapshot["skybridges"]:
		plan.skybridges.append(bridge.duplicate(true) if bridge != null else null)

func submit_plan_action(name: String, before: Dictionary, after: Dictionary, merge_key: StringName = &"") -> void:
	_submit(name, &"", Op.PLAN, before, after, merge_key)

func submit_footprint_action(name: String, id: StringName, before: Dictionary, after: Dictionary, merge_key: StringName = &"") -> void:
	if before.is_empty() or before == after:
		return
	_submit(name, id, Op.FOOTPRINT, before, after, merge_key)

func submit_bridge_action(name: String, id: StringName, before: Dictionary, after: Dictionary, merge_key: StringName = &"") -> void:
	if before.is_empty() or before == after:
		return
	_submit(name, id, Op.BRIDGE, before, after, merge_key)

func submit_terrain_action(name: String, before_slope: Vector2, after_slope: Vector2) -> void:
	if before_slope == after_slope:
		return
	_submit(name, &"", Op.TERRAIN, {"terrain_slope": before_slope}, {"terrain_slope": after_slope}, &"")

func _submit(name: String, target_id: StringName, op: int, before: Dictionary, after: Dictionary, merge_key: StringName) -> void:
	var command := PCGEditCommand.new()
	command.command_id = StringName(name)
	command.target_id = target_id
	command.scope = {"op": OP_KEYS[op]}
	command.before = before
	command.after = after
	command.merge_key = merge_key
	command.timestamp_ms = Time.get_ticks_msec()
	history.submit(command)

func _apply_entry(command: PCGEditCommand, use_after: bool) -> void:
	var patch: Dictionary = command.after if use_after else command.before
	match StringName(command.scope.get("op", &"")):
		&"plan":
			restore(patch)
		&"footprint":
			_apply_footprint_patch(command.target_id, patch)
		&"bridge":
			_apply_bridge_patch(command.target_id, patch)
		&"terrain":
			plan.terrain_slope = _denormalized(patch.get("terrain_slope", Vector2.ZERO), Vector2.ZERO)
	if _apply_callback.is_valid():
		_apply_callback.call(command, use_after)

func _apply_footprint_patch(id: StringName, patch: Dictionary) -> void:
	var footprint := plan.get_footprint(id)
	if footprint == null:
		return
	for key in patch:
		footprint.set(key, _denormalized(patch[key], footprint.get(key)))

func _apply_bridge_patch(id: StringName, patch: Dictionary) -> void:
	var bridge := plan.get_skybridge(id)
	if bridge == null or patch.is_empty():
		return
	var nodes: Array[Dictionary] = []
	for node in patch["nodes"]:
		var restored: Dictionary = (node as Dictionary).duplicate(true)
		if restored.get("position") is Array:
			var position: Array = restored["position"]
			restored["position"] = Vector3(float(position[0]), float(position[1]), float(position[2]))
		# 规范化补丁中 in/out 手柄也是数组，必须同样还原为 Vector3，否则拖拽/采样全部报错。
		for kind in [&"in", &"out"]:
			if restored.get(kind) is Array:
				var handle: Array = restored[kind]
				restored[kind] = Vector3(float(handle[0]), float(handle[1]), float(handle[2]))
		nodes.append(restored)
	bridge.nodes = nodes
	bridge.auto_lift = float(patch["auto_lift"])
	bridge.width = float(patch["width"])
	bridge.height = float(patch["height"])
	bridge.color = _denormalized(patch["color"], bridge.color)

# PCGEditCommandHistory 提交前会把 Color/Vector2/Vector3 规范化成浮点数组；
# 应用补丁时按目标属性当前类型还原，保持与旧快照应用路径一致。
static func _denormalized(value: Variant, reference: Variant) -> Variant:
	if reference is Color and value is Array and value.size() == 4:
		return Color(float(value[0]), float(value[1]), float(value[2]), float(value[3]))
	if reference is Vector3 and value is Array and value.size() == 3:
		return Vector3(float(value[0]), float(value[1]), float(value[2]))
	if reference is Vector2 and value is Array and value.size() == 2:
		return Vector2(float(value[0]), float(value[1]))
	return value
