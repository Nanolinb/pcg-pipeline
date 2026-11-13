extends SceneTree

# v0.14 编辑命令专项测试（headless）。
# 运行: Godot --headless --path <根工程> -s scripts/tests/run_edit_command_test.gd
# 用真实 Godot UndoRedo + 桩目标驱动共享包 PCGEditCommand/PCGEditCommandHistory，
# 覆盖创建/参数编辑/撤销/重做/连续拖动合并/800ms 窗口过期/穿插命令/
# 补丁哈希一致(T10)/1e-5 量化口径(T7)。任一检查失败返回非零退出码。

const COMMAND_SCRIPT_PATH := "res://addons/pcg_shared/pcg_edit_command.gd"
const HISTORY_SCRIPT_PATH := "res://addons/pcg_shared/edit_command_history.gd"
const CODEC_SCRIPT_PATH := "res://addons/pcg_shared/material_profile_codec.gd"
const PLUGIN_SCRIPT_PATH := "res://addons/surface_components/editor_plugin.gd"

var checks_run := 0
var failures: Array[String] = []

var _command_script: GDScript
var _history_script: GDScript
var _codec_script: GDScript
var _undo: UndoRedo
var _history: RefCounted
var _target_state := {}
var _apply_count := 0

func _initialize() -> void:
	print("EDIT_CMD_BEGIN: shared edit command checks")
	_command_script = load(COMMAND_SCRIPT_PATH)
	_history_script = load(HISTORY_SCRIPT_PATH)
	_codec_script = load(CODEC_SCRIPT_PATH)
	_check_scripts_compile()
	_check_command_data_model()
	_check_quantization()
	_check_nested_dictionary_hash_stability()
	_check_create_undo_redo()
	_check_param_undo_redo()
	_check_drag_merge_single_history()
	_check_interleaving_breaks_merge()
	_check_merge_window_expiry()
	_check_empty_merge_key_never_merges()
	_check_undo_closes_merge()
	_check_history_reset()
	_check_patch_hash_stable_across_redo()
	print("EDIT_CMD_CHECKS: %d run, %d failed" % [checks_run, failures.size()])
	if failures.is_empty():
		print("EDIT_CMD_RESULT: PASS")
		_finish(0)
	else:
		for failure in failures:
			print("EDIT_CMD_RESULT_FAIL: " + failure)
		_finish(1)

func _finish(code: int) -> void:
	_history = null
	_undo = null
	_command_script = null
	_history_script = null
	_codec_script = null
	_target_state.clear()
	quit(code)

func _record(ok: bool, name: String, detail: String = "") -> void:
	checks_run += 1
	if ok:
		print("EDIT_CMD_CHECK_PASS: %s%s" % [name, "" if detail.is_empty() else " (" + detail + ")"])
	else:
		failures.append(name + ("" if detail.is_empty() else " (" + detail + ")"))
		print("EDIT_CMD_CHECK_FAIL: %s%s" % [name, "" if detail.is_empty() else " (" + detail + ")"])

func _make_history() -> void:
	_undo = UndoRedo.new()
	_target_state = {}
	_apply_count = 0
	_history = _history_script.new(_undo, _apply_entry)

func _apply_entry(command: RefCounted, use_after: bool) -> void:
	# 桩目标：param 补丁按键合并（before/after 携带相同键集，撤销即恢复旧值）；
	# create 的 before 为空补丁，语义是“目标不存在”，撤销时移除桩状态。
	if StringName(command.scope.get("op", &"param")) == &"create" and not use_after:
		_target_state = {}
		_apply_count += 1
		return
	var patch: Dictionary = command.after if use_after else command.before
	for key in patch:
		_target_state[key] = patch[key]
	_apply_count += 1

func _make_command(id: StringName, target: StringName, before: Dictionary, after: Dictionary, merge_key: StringName, timestamp_ms: int) -> RefCounted:
	var command: RefCounted = _command_script.new()
	command.command_id = id
	command.target_id = target
	command.scope = {"op": &"param"}
	command.before = before
	command.after = after
	command.merge_key = merge_key
	command.timestamp_ms = timestamp_ms
	return command

func _check_scripts_compile() -> void:
	_record(_command_script != null and _command_script.can_instantiate(), "pcg_edit_command.gd compiles", COMMAND_SCRIPT_PATH)
	_record(_history_script != null and _history_script.can_instantiate(), "edit_command_history.gd compiles", HISTORY_SCRIPT_PATH)
	_record(_codec_script != null, "material_profile_codec.gd compiles", CODEC_SCRIPT_PATH)
	var plugin_script: GDScript = load(PLUGIN_SCRIPT_PATH)
	_record(plugin_script != null and plugin_script.can_instantiate(), "editor_plugin.gd compiles with command integration", PLUGIN_SCRIPT_PATH)

func _check_command_data_model() -> void:
	if _command_script == null:
		_record(false, "command data model checks skipped (script missing)")
		return
	var command: RefCounted = _command_script.new()
	command.command_id = &"place"
	command.target_id = &"surface_component_1"
	command.scope = {"op": &"create", "definition_id": "round_window"}
	command.before = {}
	command.after = {"anchor": Vector2(0.5, 1.25)}
	command.merge_key = &"drag_move:surface_component_1:3"
	command.timestamp_ms = 1234
	var copy: RefCounted = _command_script.new()
	_record(copy.from_dict(command.to_dict()) and copy.patch_hash() == command.patch_hash(),
		"command to_dict/from_dict round-trip preserves patch hash")
	_record(not copy.from_dict({"target_id": "x"}), "from_dict rejects missing command_id")

func _check_quantization() -> void:
	if _codec_script == null:
		_record(false, "quantization checks skipped (codec missing)")
		return
	var near: String = _codec_script.hash_dict({"value": 1.0})
	var closer: String = _codec_script.hash_dict({"value": 1.0000001})
	var beyond: String = _codec_script.hash_dict({"value": 1.00001})
	_record(near == closer, "T7: 1.0 and 1.0000001 quantize equal")
	_record(near != beyond, "T7: 1.0 and 1.00001 quantize different")
	var command: RefCounted = _command_script.new()
	command.after = {"anchor": Vector2(1.0, 2.0)}
	var normalized: Dictionary = command.normalize_patch(command.after)
	_record(normalized["anchor"] is Array and normalized["anchor"][0] is float,
		"anchor normalizes to float array")

func _check_nested_dictionary_hash_stability() -> void:
	if _codec_script == null or _command_script == null:
		_record(false, "nested dictionary hash checks skipped (scripts missing)")
		return
	# 嵌套 Dictionary 键序不影响哈希（旧 str() 嵌套实现的不稳定点）。
	var forward: String = _codec_script.hash_dict(
		{"outer": {"beta": 1, "alpha": 2}, "list": [{"y": 1.0, "x": 2.0}]})
	var reordered: String = _codec_script.hash_dict(
		{"list": [{"x": 2.0, "y": 1.0}], "outer": {"alpha": 2, "beta": 1}})
	_record(forward == reordered, "nested dictionary key order does not affect hash")
	_record(_codec_script.hash_dict({"outer": {"alpha": 2, "beta": 1}})
		!= _codec_script.hash_dict({"outer": {"alpha": 2, "beta": 3}}),
		"nested dictionary content change alters hash")
	# 委托关系：hash_dict / patch_hash 即 PCGCanonicalSerializer.hash_document。
	var doc := {"target_id": "surface_component_1", "scope": {"op": "param"},
		"before": {"cfg": {"x": 1.0}}, "after": {"cfg": {"x": 2.0}}}
	_record(_codec_script.hash_dict(doc) == PCGCanonicalSerializer.hash_document(doc),
		"hash_dict delegates to PCGCanonicalSerializer")
	var command: RefCounted = _command_script.new()
	command.target_id = &"surface_component_1"
	command.scope = {"op": &"param"}
	command.before = {"cfg": {"y": 1.0, "x": 2.0}}
	command.after = {"cfg": {"x": 2.0, "y": 1.0}}
	var hash_a: String = command.patch_hash()
	command.before = {"cfg": {"x": 2.0, "y": 1.0}}
	command.after = {"cfg": {"y": 1.0, "x": 2.0}}
	_record(hash_a == command.patch_hash(),
		"patch_hash stable across nested dictionary key order")
	_record(command.patch_hash() == PCGCanonicalSerializer.hash_document({
		"target_id": String(command.target_id), "scope": command.scope,
		"before": command.before, "after": command.after}),
		"patch_hash delegates to PCGCanonicalSerializer")

func _check_create_undo_redo() -> void:
	_make_history()
	var command := _make_command(&"放置表面组件", &"surface_component_1", {}, {"anchor": Vector2(0.5, 0.0)}, &"", 1000)
	command.scope = {"op": &"create"}
	_history.submit(command)
	_record(_target_state == {"anchor": [0.5, 0.0]}, "create command applies after patch")
	_history.undo()
	_record(_target_state.is_empty(), "undo of create restores empty before")
	_history.redo()
	_record(_target_state == {"anchor": [0.5, 0.0]}, "redo of create reapplies after patch")
	_record(_history.committed_count() == 1, "create committed once")

func _check_param_undo_redo() -> void:
	_make_history()
	_target_state = {"anchor": [0.0, 0.0], "attachment_angle_degrees": 0.0}
	var command := _make_command(&"设置法线倾角", &"surface_component_1",
		{"anchor": [0.0, 0.0], "attachment_angle_degrees": 0.0},
		{"anchor": [0.0, 0.0], "attachment_angle_degrees": 25.0}, &"", 1000)
	_history.submit(command)
	_record(is_equal_approx(float(_target_state["attachment_angle_degrees"]), 25.0), "param edit applies after patch")
	_history.undo()
	_record(is_equal_approx(float(_target_state["attachment_angle_degrees"]), 0.0), "undo of param edit restores before patch")

func _check_drag_merge_single_history() -> void:
	_make_history()
	var start := {"anchor": [0.0, 0.0]}
	_target_state = start.duplicate()
	var key := &"drag_move:surface_component_1:1"
	_history.submit(_make_command(&"拖动表面组件", &"surface_component_1", start, {"anchor": [0.1, 0.0]}, key, 1000))
	_history.submit(_make_command(&"拖动表面组件", &"surface_component_1", {"anchor": [0.1, 0.0]}, {"anchor": [0.4, 0.0]}, key, 1200))
	_history.submit(_make_command(&"拖动表面组件", &"surface_component_1", {"anchor": [0.4, 0.0]}, {"anchor": [0.9, 0.0]}, key, 1400))
	_record(_history.committed_count() == 1, "three drag submissions merge into one history entry",
		"committed=%d" % _history.committed_count())
	_record(_target_state == {"anchor": [0.9, 0.0]}, "merged drag ends at latest after")
	_record(_apply_count == 3, "every merged submission re-applies patch entry")
	_history.undo()
	_record(_target_state == start, "one undo restores drag start (single history entry)")
	_history.redo()
	_record(_target_state == {"anchor": [0.9, 0.0]}, "redo reapplies merged latest after")

func _check_interleaving_breaks_merge() -> void:
	_make_history()
	var start := {"anchor": [0.0, 0.0], "attachment_angle_degrees": 0.0}
	_target_state = start.duplicate()
	var key := &"drag_move:surface_component_1:1"
	_history.submit(_make_command(&"拖动表面组件", &"surface_component_1",
		start, {"anchor": [0.5, 0.0], "attachment_angle_degrees": 0.0}, key, 1000))
	_history.submit(_make_command(&"设置法线倾角", &"surface_component_1",
		{"anchor": [0.5, 0.0], "attachment_angle_degrees": 0.0},
		{"anchor": [0.5, 0.0], "attachment_angle_degrees": 10.0}, &"", 1100))
	_history.submit(_make_command(&"拖动表面组件", &"surface_component_1",
		{"anchor": [0.5, 0.0], "attachment_angle_degrees": 10.0},
		{"anchor": [0.9, 0.0], "attachment_angle_degrees": 10.0}, key, 1200))
	_record(_history.committed_count() == 3, "interleaving command breaks merge", "committed=%d" % _history.committed_count())
	_history.undo()
	_record(_target_state == {"anchor": [0.5, 0.0], "attachment_angle_degrees": 10.0}, "first undo reverts second drag only")
	_history.undo()
	_history.undo()
	_record(_target_state == start, "three undos restore drag start")

func _check_merge_window_expiry() -> void:
	_make_history()
	var start := {"anchor": [0.0, 0.0]}
	_target_state = start.duplicate()
	var key := &"drag_handle:scale:surface_component_1:1"
	_history.submit(_make_command(&"调整组件缩放", &"surface_component_1", start, {"user_scale": 1.1}, key, 1000))
	_history.submit(_make_command(&"调整组件缩放", &"surface_component_1", {"user_scale": 1.1}, {"user_scale": 1.4}, key, 2000))
	_record(_history.committed_count() == 2, "submissions 900ms apart do not merge", "committed=%d" % _history.committed_count())

func _check_empty_merge_key_never_merges() -> void:
	_make_history()
	_target_state = {}
	_history.submit(_make_command(&"设置过渡厚度", &"surface_component_1", {}, {"transition_thickness": 0.2}, &"", 1000))
	_history.submit(_make_command(&"设置过渡厚度", &"surface_component_1", {"transition_thickness": 0.2}, {"transition_thickness": 0.4}, &"", 1100))
	_record(_history.committed_count() == 2, "empty merge_key never merges")

func _check_undo_closes_merge() -> void:
	_make_history()
	_target_state = {}
	var key := &"drag_move:surface_component_1:1"
	_history.submit(_make_command(&"拖动表面组件", &"surface_component_1", {}, {"anchor": [0.5, 0.0]}, key, 1000))
	_history.undo()
	_history.submit(_make_command(&"拖动表面组件", &"surface_component_1", {}, {"anchor": [0.8, 0.0]}, key, 1100))
	_record(_history.committed_count() == 2, "submit after undo opens a new entry, no stale merge")

func _check_history_reset() -> void:
	_make_history()
	_target_state = {}
	_history.submit(_make_command(&"合并表面组件", &"surface_component_1", {}, {"merged": true}, &"merge:1", 1000))
	_history.clear_history()
	_record(_history.committed_count() == 0, "merge boundary clears committed history")
	_history.submit(_make_command(&"合并后拖动", &"surface_component_1", {}, {"anchor": [1.0, 0.0]}, &"merge:1", 1100))
	_record(_history.committed_count() == 1, "merge boundary prevents stale pending merge")

func _check_patch_hash_stable_across_redo() -> void:
	_make_history()
	var command := _make_command(&"设置过渡弧度", &"surface_component_1",
		{"transition_curvature": 0.65}, {"transition_curvature": -0.5}, &"", 1000)
	var hash_do: String = command.patch_hash()
	_history.submit(command)
	_history.undo()
	var hash_undo: String = command.patch_hash()
	_history.redo()
	var hash_redo: String = command.patch_hash()
	_record(hash_do == hash_undo and hash_undo == hash_redo,
		"T10: patch hash identical across do/undo/redo")
	_record(is_equal_approx(float(_target_state["transition_curvature"]), -0.5),
		"state after redo matches after patch")
