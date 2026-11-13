@tool
class_name PCGJsonDocumentStore
extends RefCounted

# 通用 JSON 文档持久化骨架：format_version 信封 + PCGAtomicStore 原子写入 +
# 目录枚举（坏文件 / 空 ID / 重复 ID 记入 last_report，绝不静默跳过）。
# 子类只保留各自差异：默认目录、文档后缀、from_dict 校验与发布/网格逻辑。
# 注意：GDScript 中子类一旦自定义 _init 就不会自动执行本类 _init，
# 因此子类不要覆盖 _init；默认目录通过重写 default_directory() 提供。

var directory := ""
var atomic_store: PCGAtomicStore = PCGAtomicStore.new()
## 最近一次 list_documents 的逐文件报告（含坏文件与重复 ID 说明）。
var last_report: Array[String] = []


func _init() -> void:
	directory = default_directory()
	atomic_store.content_validator = validate_envelope_content


## 子类重写以提供自己的默认目录。
func default_directory() -> String:
	return ""


## 信封内容校验（PCGAtomicStore.content_validator 签名）。
static func validate_envelope_content(content: String) -> Array[String]:
	var problems: Array[String] = []
	var json := JSON.new()
	if json.parse(content) != OK or not (json.data is Dictionary):
		problems.append("document is not a valid JSON object")
	elif not (json.data as Dictionary).has("format_version"):
		problems.append("document has no format_version")
	return problems


## 读取并校验 JSON 信封。返回 {ok, payload, errors}；坏文件给出可读错误。
static func parse_envelope(path: String, supported_version: int) -> Dictionary:
	if not FileAccess.file_exists(path):
		return {"ok": false, "payload": null, "errors": ["file not found: %s" % path]}
	var json := JSON.new()
	if json.parse(FileAccess.get_file_as_string(path)) != OK:
		return {"ok": false, "payload": null,
			"errors": ["invalid JSON in %s (line %d)" % [path, json.get_error_line()]]}
	if not (json.data is Dictionary):
		return {"ok": false, "payload": null, "errors": ["%s is not a JSON object" % path]}
	var document := json.data as Dictionary
	var version := int(document.get("format_version", 0))
	if version > supported_version:
		return {"ok": false, "payload": null,
			"errors": ["%s format_version %d is newer than supported %d"
				% [path, version, supported_version]]}
	if not (document.get("payload") is Dictionary):
		return {"ok": false, "payload": null, "errors": ["%s has no payload object" % path]}
	return {"ok": true, "payload": document["payload"] as Dictionary, "errors": PackedStringArray()}


## 枚举目录内 suffix 结尾的全部文档。
## load_one(path) 返回 {ok, item, id, id_label, empty_id_note, errors}；
## 坏文件、空 ID 与重复 ID 记入 last_report，重复 ID 只保留首个。
func list_documents(target_directory: String, suffix: String, load_one: Callable) -> Array:
	last_report = []
	var items: Array = []
	var dir := _resolve_dir(target_directory)
	var seen_ids := {}
	var dir_access := DirAccess.open(dir)
	if dir_access == null:
		last_report.append("directory not readable: %s" % dir)
		return items
	var file_names := dir_access.get_files()
	file_names.sort()
	for file_name in file_names:
		if not file_name.ends_with(suffix):
			continue
		var path := dir + "/" + file_name
		var loaded: Dictionary = load_one.call(path)
		if not loaded.get("ok", false):
			last_report.append("%s: %s" % [file_name, "; ".join(loaded.get("errors", []))])
			continue
		var id := String(loaded.get("id", ""))
		if id.is_empty():
			last_report.append("%s: %s" % [file_name, String(loaded.get("empty_id_note", "id is empty"))])
			continue
		if seen_ids.has(id):
			last_report.append("%s: duplicate %s \"%s\" (already loaded from %s); skipped"
				% [file_name, String(loaded.get("id_label", "id")), id, seen_ids[id]])
			continue
		seen_ids[id] = file_name
		items.append(loaded.get("item"))
	return items


func _resolve_dir(target_directory: String) -> String:
	return target_directory if not target_directory.is_empty() else directory
