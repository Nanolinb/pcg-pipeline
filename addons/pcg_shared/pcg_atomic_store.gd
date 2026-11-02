class_name PCGAtomicStore
extends RefCounted

# v0.14 公共内核：原子保存、轮换备份与中断恢复（docs/core_contracts.md §6）。
#
# 提交顺序：临时文件（同目录、flush+close）→ 旧正式文件保留为 .bak1 →
# 同文件系统原子替换。测试用 fault 参数模拟写入中断，不强制终止进程。
#
# - 临时文件残留但正式文件完整：recover() 清理临时文件并记录，不改变正式数据。
# - 正式文件损坏且备份存在：recover() 返回 needs_recovery 与可读恢复提示，
#   绝不静默覆盖或自动丢弃最近一致状态；只有调用方显式确认后才 restore_backup()。

const TEMP_SUFFIX := ".tmp"
const BACKUP_SUFFIX := ".bak1"

## 正式文件内容校验：Callable(content:String) -> Array[String]，空数组 = 有效。
## 未设置时按“存在且非空”判定。
var content_validator: Callable = Callable()


func save(path: String, content: String, fault: String = "") -> Dictionary:
	# 返回 {ok, error, fault}；fault 非空时 ok=false，表示注入的写入中断。
	var temp_path := _temp_path(path)
	var file := FileAccess.open(temp_path, FileAccess.WRITE)
	if file == null:
		return _result(false, "cannot open temp file %s (err=%d)" % [temp_path, FileAccess.get_open_error()], "")
	file.store_string(content)
	file.flush()
	file.close()
	if fault == "after_temp_write":
		return _result(false, "injected fault after temp write", fault)

	var formal_path := ProjectSettings.globalize_path(path)
	var backup_path := ProjectSettings.globalize_path(_backup_path(path))
	if FileAccess.file_exists(path):
		if FileAccess.file_exists(_backup_path(path)):
			DirAccess.remove_absolute(backup_path)
		if DirAccess.copy_absolute(formal_path, backup_path) != OK:
			DirAccess.remove_absolute(ProjectSettings.globalize_path(temp_path))
			return _result(false, "cannot rotate backup %s" % _backup_path(path), "")
	if fault == "after_backup":
		return _result(false, "injected fault after backup rotation", fault)
	if fault == "before_commit":
		return _result(false, "injected fault before atomic commit", fault)

	if DirAccess.rename_absolute(ProjectSettings.globalize_path(temp_path), formal_path) != OK:
		return _result(false, "atomic commit failed for %s; temp retained for recovery" % path, "")
	return _result(true, "", "")


func inspect(path: String) -> Dictionary:
	return {
		"formal_exists": FileAccess.file_exists(path),
		"formal_valid": is_formal_valid(path),
		"temp_exists": FileAccess.file_exists(_temp_path(path)),
		"backup_exists": FileAccess.file_exists(_backup_path(path)),
	}


func is_formal_valid(path: String) -> bool:
	if not FileAccess.file_exists(path):
		return false
	var content := FileAccess.get_file_as_string(path)
	if content_validator.is_valid():
		var problems: Variant = content_validator.call(content)
		return (problems is Array) and (problems as Array).is_empty()
	return not content.is_empty()


func recover(path: String, user_confirmed: bool = false) -> Dictionary:
	# 返回恢复报告；除清理临时残留外不产生任何写操作，
	# 除非 user_confirmed=true 且确实需要恢复备份。
	var state := inspect(path)
	var notes: Array[String] = []
	var action := "none"
	if state["formal_valid"] and state["temp_exists"]:
		# 临时文件残留但正式文件完整：清理临时文件并记录，不改变正式数据。
		DirAccess.remove_absolute(ProjectSettings.globalize_path(_temp_path(path)))
		notes.append("removed stale temp file %s; formal data untouched" % _temp_path(path))
		action = "cleaned_temp"
	elif not state["formal_valid"]:
		if state["backup_exists"]:
			if user_confirmed:
				var err := restore_backup(path)
				if err == OK:
					action = "restored_backup"
					notes.append("restored %s from %s" % [path, _backup_path(path)])
				else:
					action = "unrecoverable"
					notes.append("restore_backup failed err=%d" % err)
			else:
				# 提示用户恢复；不得静默覆盖或自动丢弃最近一致状态。
				action = "needs_recovery"
				notes.append("formal file %s is missing or corrupt" % path)
				notes.append("most recent consistent copy: %s" % _backup_path(path))
				notes.append("call restore_backup() or recover(path, true) after user confirms")
		else:
			action = "unrecoverable"
			notes.append("formal file %s is missing or corrupt and no backup exists" % path)
	return {
		"action": action,
		"recovery_prompt": String("; ").join(PackedStringArray(notes)) if action == "needs_recovery" else "",
		"notes": PackedStringArray(notes),
		"formal_valid_before": state["formal_valid"],
		"backup_existed": state["backup_exists"],
		"temp_existed": state["temp_exists"],
	}


func restore_backup(path: String) -> Error:
	if not FileAccess.file_exists(_backup_path(path)):
		return ERR_FILE_NOT_FOUND
	return DirAccess.copy_absolute(ProjectSettings.globalize_path(_backup_path(path)),
		ProjectSettings.globalize_path(path))


func _temp_path(path: String) -> String:
	return path + TEMP_SUFFIX


func _backup_path(path: String) -> String:
	return path + BACKUP_SUFFIX


func _result(ok: bool, error: String, fault: String) -> Dictionary:
	return {"ok": ok, "error": error, "fault": fault}
