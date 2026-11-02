class_name PCGFormatMigrator
extends RefCounted

# v0.14 公共内核：持久化文档格式版本与逐级迁移（docs/core_contracts.md §1.2）。
#
# 文档信封固定为：
#   { "format_version": int, "app_version": String, "payload": Dictionary }
#
# 加载顺序固定为：读取 → 检查 format_version → 逐级迁移 → 字段校验 → 构建。
# - migrate(document, from_version) -> Dictionary 的迁移 Callable 逐级把文档
#   从 from_version 迁到 from_version + 1，并负责把信封 format_version 写成新版本。
# - from_version 高于当前版本时返回可读“版本过新”错误，不静默解释。
# - 校验失败返回全部字段错误，document 为空，调用方不得构建半份场景。

const KEY_FORMAT_VERSION := "format_version"
const KEY_APP_VERSION := "app_version"
const KEY_PAYLOAD := "payload"

var current_format_version: int
var _migrations: Dictionary = {}  # from_version:int -> Callable(document, from_version) -> Dictionary
var _payload_validator: Callable = Callable()  # payload:Dictionary -> Array[String]


func _init(p_current_format_version: int) -> void:
	current_format_version = p_current_format_version


func add_migration(from_version: int, migration: Callable) -> void:
	_migrations[from_version] = migration


func set_payload_validator(validator: Callable) -> void:
	_payload_validator = validator


func save_document(payload: Dictionary, app_version: String) -> Dictionary:
	return {
		KEY_FORMAT_VERSION: current_format_version,
		KEY_APP_VERSION: app_version,
		KEY_PAYLOAD: payload,
	}


func load_document_file(path: String) -> Dictionary:
	# 读取 + 检查 + 迁移 + 校验一步完成；ok=false 时 document 保证为空字典。
	var text := FileAccess.get_file_as_string(path)
	if text.is_empty() and FileAccess.get_open_error() != OK:
		return _failure(["cannot read file: %s (err=%d)" % [path, FileAccess.get_open_error()]])
	return parse_document(text)


func parse_document(text: String) -> Dictionary:
	var json := JSON.new()
	if json.parse(text) != OK:
		return _failure(["JSON parse error at line %d: %s" % [json.get_error_line(), json.get_error_message()]])
	var document: Variant = json.data
	if not (document is Dictionary):
		return _failure(["document root must be a Dictionary"])
	return migrate_document(document)


func migrate_document(document: Dictionary) -> Dictionary:
	var errors: Array[String] = []
	var working: Dictionary = document.duplicate(true)
	if not working.has(KEY_FORMAT_VERSION):
		return _failure(["missing or non-int field: format_version"])
	if not working.has(KEY_PAYLOAD):
		return _failure(["missing field: payload"])
	var raw_version: Variant = working[KEY_FORMAT_VERSION]
	var version_is_int := raw_version is int \
		or (raw_version is float and is_equal_approx(raw_version, round(raw_version)))
	if not version_is_int:
		return _failure(["missing or non-int field: format_version"])
	var from_version := int(raw_version)
	if from_version > current_format_version:
		return _failure(["format_version %d is newer than supported version %d; refusing to interpret" % [from_version, current_format_version]])
	var guard := 0
	while from_version < current_format_version:
		guard += 1
		if guard > 1024:
			return _failure(["migration chain loop detected at version %d" % from_version])
		if not _migrations.has(from_version):
			return _failure(["no migration registered from format_version %d to %d" % [from_version, from_version + 1]])
		var migrated: Variant = _migrations[from_version].call(working.duplicate(true), from_version)
		if not (migrated is Dictionary):
			return _failure(["migration from version %d did not return a Dictionary" % from_version])
		working = migrated
		if not working.has(KEY_FORMAT_VERSION) or int(working.get(KEY_FORMAT_VERSION, from_version)) != from_version + 1:
			return _failure(["migration from version %d must set format_version to %d" % [from_version, from_version + 1]])
		from_version = working[KEY_FORMAT_VERSION]
	if _payload_validator.is_valid():
		var payload_errors: Variant = _payload_validator.call(working.get(KEY_PAYLOAD, {}))
		if payload_errors is Array:
			for problem in payload_errors:
				errors.append(String(problem))
	if not errors.is_empty():
		return _failure(errors)
	return {"ok": true, "errors": PackedStringArray(), "document": working}


func _failure(errors: Array[String]) -> Dictionary:
	# 校验失败：列出全部字段错误，不产出半份文档。
	return {"ok": false, "errors": PackedStringArray(errors), "document": {}}
