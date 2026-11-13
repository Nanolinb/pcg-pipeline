@tool
class_name PCGAssetTaskStore
extends PCGJsonDocumentStore

# v0.15 L0 资产任务持久化：PCGJsonDocumentStore 骨架 + format_version 信封。
# 默认目录 res://assets/tasks，可被调用方覆盖（例如 user:// 测试目录）。
# list_tasks 对重复 ID / 坏文件给出明确报告（last_report），绝不静默跳过。

const DEFAULT_DIRECTORY := "res://assets/tasks"
const FILE_SUFFIX := ".task.json"


func default_directory() -> String:
	return DEFAULT_DIRECTORY


func task_path(task_id: StringName, task_directory: String = "") -> String:
	return _resolve_dir(task_directory) + "/" + String(task_id) + FILE_SUFFIX


func save_task(task: PCGAssetTask, task_directory: String = "", fault: String = "") -> Dictionary:
	# 返回 {ok, path, errors}；校验不过不触碰磁盘，原子写入中断不破坏已有正式文件。
	var errors: Array[String] = task.validation_errors(true)
	if not errors.is_empty():
		return {"ok": false, "path": "", "errors": errors}
	var dir := _resolve_dir(task_directory)
	if DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(dir)) != OK:
		return {"ok": false, "path": "", "errors": ["cannot create directory %s" % dir]}
	var path := task_path(task.task_id, dir)
	var document := {
		"format_version": PCGAssetTask.FORMAT_VERSION,
		"app_version": "0.15.0",
		"payload": task.to_dict(),
	}
	var saved: Dictionary = atomic_store.save(path, JSON.stringify(document, "\t"), fault)
	if not saved["ok"]:
		return {"ok": false, "path": path,
			"errors": [String(saved.get("error", "atomic save failed"))]}
	return {"ok": true, "path": path, "errors": PackedStringArray()}


func load_task(path: String) -> Dictionary:
	# 返回 {ok, task, errors}；坏文件给出可读错误，绝不返回半份任务。
	var parsed := parse_envelope(path, PCGAssetTask.FORMAT_VERSION)
	if not parsed["ok"]:
		return {"ok": false, "task": null, "errors": parsed["errors"]}
	var task := PCGAssetTask.new()
	var errors: Array[String] = task.from_dict(parsed["payload"] as Dictionary)
	if not errors.is_empty():
		return {"ok": false, "task": null, "errors": errors}
	return {"ok": true, "task": task, "errors": PackedStringArray()}


func list_tasks(task_directory: String = "") -> Array[PCGAssetTask]:
	# 载入目录内全部 .task.json；坏文件与重复 ID 记录在 last_report，
	# 重复 ID 只保留首个，绝不静默跳过。
	var tasks: Array[PCGAssetTask] = []
	tasks.assign(list_documents(task_directory, FILE_SUFFIX, _load_task_entry))
	return tasks


func _load_task_entry(path: String) -> Dictionary:
	var loaded := load_task(path)
	if not loaded["ok"]:
		return {"ok": false, "errors": loaded["errors"]}
	var task: PCGAssetTask = loaded["task"]
	return {"ok": true, "item": task, "id": String(task.task_id),
		"id_label": "task_id", "empty_id_note": "payload task_id is empty"}
