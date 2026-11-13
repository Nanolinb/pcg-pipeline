class_name PipePresetCatalog
extends RefCounted

const DEFAULT_DIRECTORY := "res://assets/presets"

## 预设目录；可在 load_all() 前覆盖（例如测试指向 user:// 夹具目录）。
var directory: String = DEFAULT_DIRECTORY
var definitions: Array = []
var errors: Array[String] = []

func load_all() -> void:
	definitions.clear()
	errors.clear()
	if not DirAccess.dir_exists_absolute(directory):
		errors.append("预设目录不存在：%s" % directory)
		return
	var file_names := DirAccess.get_files_at(directory)
	file_names.sort()
	var seen_ids := {}
	for file_name in file_names:
		if not file_name.ends_with(".tres"):
			continue
		var path: String = directory.path_join(file_name)
		var resource: Resource = load(path)
		if not resource is PipePreset:
			errors.append("%s 不是 PipePreset。" % path)
			continue
		var preset: PipePreset = resource
		if preset.id.is_empty() or preset.display_name.is_empty():
			errors.append("%s 缺少 id 或 display_name。" % path)
			continue
		if preset.diameter <= 0.0 or preset.radial_segments < 8 or preset.default_corner_segments < 2:
			errors.append("%s 的直径或分段参数无效。" % path)
			continue
		if seen_ids.has(preset.id):
			errors.append("%s 的 id \"%s\" 与 %s 重复，已跳过。" % [path, preset.id, seen_ids[preset.id]])
			continue
		seen_ids[preset.id] = path
		definitions.append({"preset": preset, "path": path})
	definitions.sort_custom(func(a, b): return a["preset"].display_name < b["preset"].display_name)

func get_preset(index: int) -> PipePreset:
	if index < 0 or index >= definitions.size():
		return null
	return definitions[index]["preset"]
