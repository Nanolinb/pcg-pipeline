@tool
class_name PCGSharedClassResolver
extends RefCounted

# 共享类解析器：按全局类名运行时解析 pcg_shared 脚本。
# surface_components 等消费方通过 res:// 路径加载本脚本后调用，
# 共享 API 缺失时 find_shared_script 返回 null，由调用方明确报告，
# 而不是静默降级。

const DEFAULT_SHARED_DIRS: Array[String] = [
	"res://addons/pcg_shared",
]


static func find_shared_script(global_class: String, dir_candidates: Array = DEFAULT_SHARED_DIRS) -> GDScript:
	for entry in ProjectSettings.get_global_class_list():
		if String(entry.get("class", "")) == global_class:
			var script: GDScript = load(String(entry.get("path", "")))
			if script != null and script.can_instantiate():
				return script
	for dir_path in dir_candidates:
		var script := scan_dir_for_class(String(dir_path), global_class)
		if script != null:
			return script
	return null


static func scan_dir_for_class(dir_path: String, global_class: String) -> GDScript:
	var dir := DirAccess.open(dir_path)
	if dir == null:
		return null
	for file_name in dir.get_files():
		if not file_name.ends_with(".gd"):
			continue
		var full_path := dir_path.path_join(file_name)
		var file := FileAccess.open(full_path, FileAccess.READ)
		if file == null:
			continue
		if has_class_declaration(file.get_as_text(), global_class):
			var script: GDScript = load(full_path)
			if script != null and script.can_instantiate():
				return script
	return null


static func has_class_declaration(source: String, global_class: String) -> bool:
	for line in source.split("\n"):
		if line.strip_edges() == "class_name " + global_class:
			return true
	return false
