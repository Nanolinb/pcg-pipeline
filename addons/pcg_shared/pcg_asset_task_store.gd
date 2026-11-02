@tool
class_name PCGAssetTaskStore
extends RefCounted

# v0.15 L0 资产任务持久化：PCGAtomicStore + JSON + format_version 信封。
# 默认目录 res://assets/tasks，可被调用方覆盖（例如 user:// 测试目录）。
# list_tasks 对重复 ID / 坏文件给出明确报告（last_report），绝不静默跳过。

const DEFAULT_DIRECTORY := "res://assets/tasks"
const FILE_SUFFIX := ".task.json"

var directory: String = DEFAULT_DIRECTORY
var atomic_store: PCGAtomicStore = PCGAtomicStore.new()
## 最近一次 list_tasks 的逐文件报告（含坏文件与重复 ID 说明）。
var last_report: Array[String] = []


func _init() -> void:
	atomic_store.content_validator = func(content: String) -> Array[String]:
		var problems: Array[String] = []
		var json := JSON.new()
		if json.parse(content) != OK or not (json.data is Dictionary):
			problems.append("document is not a valid JSON object")
		elif not (json.data as Dictionary).has("format_version"):
			problems.append("document has no format_version")
		return problems


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
	var errors: Array[String] = []
	if not FileAccess.file_exists(path):
		return {"ok": false, "task": null, "errors": ["file not found: %s" % path]}
	var json := JSON.new()
	if json.parse(FileAccess.get_file_as_string(path)) != OK:
		return {"ok": false, "task": null,
			"errors": ["invalid JSON in %s (line %d)" % [path, json.get_error_line()]]}
	if not (json.data is Dictionary):
		return {"ok": false, "task": null, "errors": ["%s is not a JSON object" % path]}
	var document := json.data as Dictionary
	var version := int(document.get("format_version", 0))
	if version > PCGAssetTask.FORMAT_VERSION:
		return {"ok": false, "task": null,
			"errors": ["%s format_version %d is newer than supported %d"
				% [path, version, PCGAssetTask.FORMAT_VERSION]]}
	if not (document.get("payload") is Dictionary):
		return {"ok": false, "task": null, "errors": ["%s has no payload object" % path]}
	var task := PCGAssetTask.new()
	errors = task.from_dict(document["payload"] as Dictionary)
	if not errors.is_empty():
		return {"ok": false, "task": null, "errors": errors}
	return {"ok": true, "task": task, "errors": PackedStringArray()}


func list_tasks(task_directory: String = "") -> Array[PCGAssetTask]:
	# 载入目录内全部 .task.json；坏文件与重复 ID 记录在 last_report，
	# 重复 ID 只保留首个，绝不静默跳过。
	last_report = []
	var tasks: Array[PCGAssetTask] = []
	var dir := _resolve_dir(task_directory)
	var seen_ids := {}
	var dir_access := DirAccess.open(dir)
	if dir_access == null:
		last_report.append("directory not readable: %s" % dir)
		return tasks
	var file_names := dir_access.get_files()
	file_names.sort()
	for file_name in file_names:
		if not file_name.ends_with(FILE_SUFFIX):
			continue
		var path := dir + "/" + file_name
		var loaded := load_task(path)
		if not loaded["ok"]:
			last_report.append("%s: %s" % [file_name, "; ".join(loaded["errors"])])
			continue
		var task: PCGAssetTask = loaded["task"]
		var id := String(task.task_id)
		if id.is_empty():
			last_report.append("%s: payload task_id is empty" % file_name)
			continue
		if seen_ids.has(id):
			last_report.append("%s: duplicate task_id \"%s\" (already loaded from %s); skipped"
				% [file_name, id, seen_ids[id]])
			continue
		seen_ids[id] = file_name
		tasks.append(task)
	return tasks


func _resolve_dir(task_directory: String) -> String:
	return task_directory if not task_directory.is_empty() else directory
