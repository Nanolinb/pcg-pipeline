class_name PCGEditCommandHistory
extends RefCounted

# v0.14 公共内核编辑历史（docs/core_contracts.md §2）。
# 所有编辑经 Godot UndoRedo 提交；do/undo/redo 共用同一个补丁应用入口
# apply_entry(command, use_after)。同一 merge_key 在 800ms 窗口内、
# 且中间无其他命令时合并为一条历史（合并只更新 after，撤销回到
# 合并组首条命令的 before）。
#
# 注意：经编辑器 UI 直接触发的 undo/redo 不会经过本类，
# 因此调用方必须为每次连续交互生成新的 merge 会话（例如把自增
# 序号编入 merge_key），不要把跨交互复用的 merge_key 交给本类。

const MERGE_WINDOW_MS := 800

# undo_redo 同时接受引擎 UndoRedo（测试/运行时）与编辑器
# EditorUndoRedoManager（EditorPlugin.get_undo_redo()）：两者共享
# create_action/add_do_method/add_undo_method/commit_action/undo/redo 子集，
# 这里以 Object 持有并动态分发，保持共享包不依赖编辑器专属类型。
var undo_redo: Object
var apply_entry: Callable  # func(command: PCGEditCommand, use_after: bool) -> void
var committed: Array[PCGEditCommand] = []  # 合并后的顶层命令，供审计与测试

var _pending_merge: PCGEditCommand = null

func _init(p_undo_redo: Object, p_apply_entry: Callable) -> void:
	undo_redo = p_undo_redo
	apply_entry = p_apply_entry

func submit(command: PCGEditCommand) -> void:
	command.before = command.normalize_patch(command.before)
	command.after = command.normalize_patch(command.after)
	if _can_merge(command):
		_pending_merge.after = command.after
		_pending_merge.timestamp_ms = command.timestamp_ms
		apply_entry.call(_pending_merge, true)
		return
	undo_redo.create_action(String(command.command_id))
	undo_redo.add_do_method(_apply_committed.bind(command, true))
	undo_redo.add_undo_method(_apply_committed.bind(command, false))
	undo_redo.commit_action()
	committed.append(command)
	_pending_merge = command if command.merge_key != &"" else null

func undo() -> void:
	_pending_merge = null
	undo_redo.undo()

func redo() -> void:
	_pending_merge = null
	undo_redo.redo()

func committed_count() -> int:
	return committed.size()

func clear_history() -> void:
	_pending_merge = null
	committed.clear()
	undo_redo.clear_history()

func _can_merge(command: PCGEditCommand) -> bool:
	return (_pending_merge != null
		and command.merge_key != &""
		and command.merge_key == _pending_merge.merge_key
		and command.timestamp_ms >= _pending_merge.timestamp_ms
		and command.timestamp_ms - _pending_merge.timestamp_ms <= MERGE_WINDOW_MS)

func _apply_committed(command: PCGEditCommand, use_after: bool) -> void:
	_pending_merge = null
	apply_entry.call(command, use_after)
