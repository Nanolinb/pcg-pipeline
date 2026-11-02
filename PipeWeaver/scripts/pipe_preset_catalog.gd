class_name PipePresetCatalog
extends RefCounted

var definitions: Array = []
var errors: Array[String] = []

func load_all() -> void:
	definitions.clear()
	errors.clear()
	for file_name in DirAccess.get_files_at("res://assets/presets"):
		if not file_name.ends_with(".tres"):
			continue
		var path: String = "res://assets/presets/" + file_name
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
		definitions.append({"preset": preset, "path": path})
	definitions.sort_custom(func(a, b): return a["preset"].display_name < b["preset"].display_name)

func get_preset(index: int) -> PipePreset:
	if index < 0 or index >= definitions.size():
		return null
	return definitions[index]["preset"]
