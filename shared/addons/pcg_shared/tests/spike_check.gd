extends SceneTree

# BASE-05 共享载体 Spike 验证脚本（单源，随共享包分发）。
# 运行：Godot --headless --path <消费者工程> -s res://addons/pcg_shared/tests/spike_check.gd
# 在同一物理共享模块上验证：加载、资源 API、class_name/uid/Autoload/插件冲突、
# 干净重导入后的注册，以及 v0.14 迁移后主程序行为（无本地副本、.tres 由共享脚本解析、
# MaterialLibrary Autoload 指向共享模块；若该工程存在）。

const MODULE_PATH := "res://addons/pcg_shared"
const PROFILE_SCRIPT_PATH := MODULE_PATH + "/shared_material_profile.gd"
const CODEC_SCRIPT_PATH := MODULE_PATH + "/material_profile_codec.gd"
const PLUGIN_CFG_PATH := MODULE_PATH + "/plugin.cfg"
const CORE_CHECKS_SCRIPT_PATH := MODULE_PATH + "/tests/core_kernel_checks.gd"
const PROFILE_UID_PATH := MODULE_PATH + "/shared_material_profile.gd.uid"
const PROFILE_CLASS := "PCGSharedMaterialProfile"
const CODEC_CLASS := "PCGSharedMaterialCodec"
# v0.14 起从两个主程序迁入共享模块的脚本（类名 -> 文件名）。
const MIGRATED_CLASSES := {
	"PCGMaterialProfile": "material_profile.gd",
	"PCGMeshChunkBaker": "mesh_chunk_baker.gd",
	"PipeMeshBuilder": "pipe_mesh_builder.gd",
	"SurfacePathSolver": "surface_path_solver.gd",
	"PCGTextureSlotPanel": "texture_slot_panel.gd",
}
const MIGRATED_LIBRARY_SCRIPT := MODULE_PATH + "/material_library.gd"
const LOCAL_SCRIPTS_DIR := "res://scripts"

var checks_run: int = 0
var failures: Array[String] = []

func _initialize() -> void:
	print("SPIKE_BEGIN: shared addon single-source check")
	_check_module_files()
	_check_class_registration()
	_check_duplicate_class_names()
	_check_duplicate_uids()
	_check_autoload_conflicts()
	_check_plugin_descriptor()
	_check_profile_api()
	_check_codec_roundtrip()
	_check_existing_behavior_unchanged()
	_check_core_kernel()
	print("SPIKE_CHECKS: %d run, %d failed" % [checks_run, failures.size()])
	if failures.is_empty():
		print("SPIKE_RESULT: PASS")
		quit(0)
	else:
		for failure in failures:
			print("SPIKE_RESULT_FAIL: " + failure)
		quit(1)

func _record(ok: bool, name: String, detail: String = "") -> void:
	checks_run += 1
	if ok:
		print("SPIKE_CHECK_PASS: %s%s" % [name, "" if detail.is_empty() else " (" + detail + ")"])
	else:
		failures.append(name + ("" if detail.is_empty() else " (" + detail + ")"))
		print("SPIKE_CHECK_FAIL: %s%s" % [name, "" if detail.is_empty() else " (" + detail + ")"])

func _check_module_files() -> void:
	_record(FileAccess.file_exists(PROFILE_SCRIPT_PATH), "profile script reachable", PROFILE_SCRIPT_PATH)
	_record(FileAccess.file_exists(CODEC_SCRIPT_PATH), "codec script reachable", CODEC_SCRIPT_PATH)

func _check_class_registration() -> void:
	# 干净重导入后，全局类缓存必须恰好注册一次，且路径指向共享 addon。
	var cache_path := "res://.godot/global_script_class_cache.cfg"
	if not FileAccess.file_exists(cache_path):
		_record(false, "global class cache exists", cache_path)
		return
	var cache := ConfigFile.new()
	if cache.load(cache_path) != OK:
		_record(false, "global class cache parseable")
		return
	# global_script_class_cache.cfg 是默认节里的 list=[{...}] 数组。
	var entries: Array = cache.get_value("", "list", [])
	var profile_hits := 0
	var codec_hits := 0
	for entry in entries:
		var entry_class := String(entry.get("class", ""))
		if entry_class == PROFILE_CLASS:
			profile_hits += 1
			_record(String(entry.get("path", "")) == PROFILE_SCRIPT_PATH,
				"profile class path points at shared addon", String(entry.get("path", "")))
		if entry_class == CODEC_CLASS:
			codec_hits += 1
			_record(String(entry.get("path", "")) == CODEC_SCRIPT_PATH,
				"codec class path points at shared addon", String(entry.get("path", "")))
	_record(profile_hits == 1, "profile class registered exactly once", "hits=%d" % profile_hits)
	_record(codec_hits == 1, "codec class registered exactly once", "hits=%d" % codec_hits)
	for class_name_migrated in MIGRATED_CLASSES:
		var expected_file: String = MIGRATED_CLASSES[class_name_migrated]
		# 根工程内 addons/pcg_shared 是指向 shared/ 的符号链接，编辑器类缓存可能
		# 记录为 res://shared/addons/pcg_shared/...；两种前缀都视为共享模块内。
		var hits := 0
		for entry in entries:
			if String(entry.get("class", "")) == class_name_migrated:
				hits += 1
				var entry_path := String(entry.get("path", ""))
				_record(entry_path.ends_with("/pcg_shared/" + expected_file),
					"%s class path points at shared addon" % class_name_migrated, entry_path)
		_record(hits == 1, "%s registered exactly once" % class_name_migrated, "hits=%d" % hits)

func _walk_files(dir_path: String, suffix: String, results: Array[String]) -> void:
	var dir := DirAccess.open(dir_path)
	if dir == null:
		return
	for name in dir.get_files():
		if name.ends_with(suffix):
			results.append(dir_path.path_join(name))
	for name in dir.get_directories():
		if name == ".godot" or name.begins_with("."):
			continue
		_walk_files(dir_path.path_join(name), suffix, results)

func _check_duplicate_class_names() -> void:
	var scripts: Array[String] = []
	_walk_files("res://", ".gd", scripts)
	var owners := {}
	var duplicates := 0
	for script_path in scripts:
		var file := FileAccess.open(script_path, FileAccess.READ)
		if file == null:
			continue
		var found := ""
		while not file.eof_reached():
			var line := file.get_line().strip_edges()
			if line.begins_with("class_name "):
				found = line.split(" ")[1].strip_edges()
				break
			if not (line.is_empty() or line.begins_with("#") or line.begins_with("@")):
				break
		if found.is_empty():
			continue
		if owners.has(found):
			print("SPIKE_DETAIL: duplicate class_name %s: %s and %s" % [found, owners[found], script_path])
			duplicates += 1
		else:
			owners[found] = script_path
	_record(duplicates == 0, "no duplicate class_name in project", "%d scripts scanned" % scripts.size())

func _check_duplicate_uids() -> void:
	var uid_files: Array[String] = []
	_walk_files("res://", ".uid", uid_files)
	var owners := {}
	var duplicates := 0
	for uid_path in uid_files:
		var text := FileAccess.get_file_as_string(uid_path).strip_edges()
		if owners.has(text):
			print("SPIKE_DETAIL: duplicate uid %s: %s and %s" % [text, owners[text], uid_path])
			duplicates += 1
		else:
			owners[text] = uid_path
	_record(duplicates == 0, "no duplicate uid in project", "%d uid files scanned" % uid_files.size())
	# 共享模块自身的 uid 必须可被 ResourceUID 解析且指向共享路径。
	if FileAccess.file_exists(PROFILE_UID_PATH):
		var uid_text := FileAccess.get_file_as_string(PROFILE_UID_PATH).strip_edges()
		var id := ResourceUID.text_to_id(uid_text)
		var resolved := ResourceUID.has_id(id) and ResourceUID.get_id_path(id) == PROFILE_SCRIPT_PATH
		_record(resolved, "shared profile uid resolves to addon path", uid_text)
	else:
		_record(false, "shared profile uid file exists", PROFILE_UID_PATH)

func _check_autoload_conflicts() -> void:
	var names: Array[String] = []
	for property in ProjectSettings.get_property_list():
		var prop_name := String(property["name"])
		if prop_name.begins_with("autoload/"):
			names.append(prop_name.trim_prefix("autoload/"))
	var clash := names.has(PROFILE_CLASS) or names.has(CODEC_CLASS)
	print("SPIKE_DETAIL: autoloads = %s" % [", ".join(PackedStringArray(names))])
	_record(not clash, "no autoload name clash with shared classes")

func _check_plugin_descriptor() -> void:
	if not FileAccess.file_exists(PLUGIN_CFG_PATH):
		_record(false, "plugin.cfg exists", PLUGIN_CFG_PATH)
		return
	var cfg := ConfigFile.new()
	var err := cfg.load(PLUGIN_CFG_PATH)
	_record(err == OK and cfg.has_section_key("plugin", "name"), "plugin.cfg parseable",
		String(cfg.get_value("plugin", "name", "")) if err == OK else "parse error")
	var enabled := PackedStringArray(ProjectSettings.get_setting("editor_plugins/enabled", PackedStringArray()))
	print("SPIKE_DETAIL: editor plugins enabled = %s" % [", ".join(enabled)])

func _check_profile_api() -> void:
	var profile_script: GDScript = load(PROFILE_SCRIPT_PATH)
	if profile_script == null:
		_record(false, "profile script compiles", PROFILE_SCRIPT_PATH)
		return
	_record(true, "profile script compiles")
	var profile: Resource = profile_script.new()
	profile.display_name = &"spike_profile"
	profile.tint = Color(0.25, 0.5, 0.75, 1.0)
	profile.roughness = 0.4
	profile.metallic = 0.1
	profile.detail_tiling = 8.0
	_record(profile.validate().is_empty(), "valid profile passes validate()")
	profile.roughness = 2.0
	_record(not profile.validate().is_empty(), "invalid profile fails validate()")
	profile.roughness = 0.4
	var material: StandardMaterial3D = profile.build_material()
	_record(material != null and material.albedo_color == profile.tint
		and is_equal_approx(material.roughness, 0.4)
		and is_equal_approx(material.uv1_scale.x, 8.0), "build_material() reflects profile fields")
	var copy: Resource = profile_script.new()
	var dict: Dictionary = profile.to_dict()
	_record(copy.from_dict(dict) and copy.is_same_profile(profile), "to_dict/from_dict round-trip")
	var future := dict.duplicate()
	future["format_version"] = 999
	_record(not copy.from_dict(future), "future format_version rejected")

func _check_codec_roundtrip() -> void:
	var codec_script: GDScript = load(CODEC_SCRIPT_PATH)
	if codec_script == null:
		_record(false, "codec script compiles (global class registration required)", CODEC_SCRIPT_PATH)
		return
	_record(true, "codec script compiles (global classes registered)")
	var profile_script: GDScript = load(PROFILE_SCRIPT_PATH)
	var profile: Resource = profile_script.new()
	profile.display_name = &"codec_roundtrip"
	profile.roughness = 0.7
	var save_path := "user://pcg_shared_spike_profile.tres"
	var err: int = codec_script.save_profile(profile, save_path)
	_record(err == OK, "codec save_profile", "%s err=%d" % [save_path, err])
	var loaded: Resource = codec_script.load_profile(save_path)
	_record(loaded != null and loaded.is_same_profile(profile), "codec load round-trip identical")
	var twin: Resource = profile_script.new()
	twin.display_name = &"codec_roundtrip"
	twin.roughness = 0.7
	_record(codec_script.hash_profile(profile) == codec_script.hash_profile(twin),
		"semantic hash deterministic for identical profiles")
	twin.metallic = 0.9
	_record(codec_script.hash_profile(profile) != codec_script.hash_profile(twin),
		"semantic hash changes with content")
	DirAccess.remove_absolute(ProjectSettings.globalize_path(save_path))

func _check_core_kernel() -> void:
	# v0.14 公共内核专项（稳定 ID/迁移/规范化/签名/随机/原子保存）。
	# 与独立入口 tests/core_kernel_check.gd 共用同一份 PCGCoreKernelChecks。
	print("SPIKE_BEGIN: core kernel checks")
	var script: GDScript = load(CORE_CHECKS_SCRIPT_PATH)
	if script == null:
		_record(false, "core kernel checks script compiles", CORE_CHECKS_SCRIPT_PATH)
		return
	var checks: RefCounted = script.new()
	var result: Dictionary = checks.run("SPIKE_KERNEL")
	checks_run += int(result["checks_run"])
	for failure in result["failures"]:
		failures.append(String(failure))

func _check_existing_behavior_unchanged() -> void:
	# v0.14 迁移后：主程序（根工程 / PipeWeaver）不得再保留已迁移脚本的本地副本；
	# 既有 .tres 必须由共享模块里的脚本解析；MaterialLibrary Autoload 指向共享模块。
	# 第三方消费者：无本地副本、无 .tres、无 Autoload，全部条件检查自动通过。
	var local_leftovers: Array[String] = []
	for class_name_migrated in MIGRATED_CLASSES:
		var local_path: String = LOCAL_SCRIPTS_DIR + "/" + MIGRATED_CLASSES[class_name_migrated]
		if FileAccess.file_exists(local_path):
			local_leftovers.append(local_path)
	_record(local_leftovers.is_empty(), "no local copy of migrated scripts",
		", ".join(PackedStringArray(local_leftovers)))
	var library_autoload_path := String(ProjectSettings.get_setting("autoload/MaterialLibrary", ""))
	if not library_autoload_path.is_empty():
		_record(library_autoload_path == "*" + MIGRATED_LIBRARY_SCRIPT,
			"MaterialLibrary autoload points at shared addon", library_autoload_path)
		var library_script: GDScript = load(MIGRATED_LIBRARY_SCRIPT)
		_record(library_script != null, "shared material library compiles", MIGRATED_LIBRARY_SCRIPT)
	else:
		_record(true, "consumer isolation: no MaterialLibrary autoload present")
	var profile_script: GDScript = load(MODULE_PATH + "/material_profile.gd")
	_record(profile_script != null, "shared PCGMaterialProfile loads")
	if profile_script != null:
		var profile: Resource = profile_script.new()
		_record(profile.texture_for_slot(&"base_color") == null
			and profile.texture_for_slot(&"bogus") == null, "shared profile API intact")
	for tres_path in ["res://assets/materials/round_window_frame.tres",
			"res://assets/materials/square_window_frame.tres",
			"res://assets/materials/round_window_glass.tres",
			"res://assets/materials/square_window_glass.tres",
			"res://assets/pipe_material.tres"]:
		if FileAccess.file_exists(tres_path):
			var resource := ResourceLoader.load(tres_path)
			_record(resource != null and resource.get_script() == profile_script,
				"existing .tres resolves shared profile", tres_path)
