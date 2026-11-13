extends Node

# PipePresetCatalog 回归（审查门禁）：预设目录加载、损坏资源、重复 ID、
# 缺失目录，以及在真实 main 场景中应用预设后网格参数/顶点数与材质的变化。
# 运行：Godot --headless --path PipeWeaver res://tests/pipe_preset_catalog_test.tscn
# 失败时进程以非零退出码结束，并逐条打印 PRESET_CATALOG_FAIL。

const MainScene := preload("res://scenes/main.tscn")
const PresetCatalogScript := preload("res://scripts/pipe_preset_catalog.gd")
const PipePresetScript := preload("res://scripts/pipe_preset.gd")

const OFFICIAL_PRESET_IDS: Array[String] = [
	"cable_conduit",
	"copper_gas",
	"high_pressure_steam",
	"industrial_water",
	"pvc_drain",
]
## 示例管道的基线环向分段（main.gd 默认值）；所选预设必须与之不同才能观察到顶点数变化。
const BASELINE_RADIAL_SEGMENTS := 24
const FIXTURE_ROOT := "user://preset_catalog_test"

var checks_run: int = 0
var failures: Array[String] = []

func _ready() -> void:
	print("PRESET_CATALOG_BEGIN")
	_reset_fixture_root()
	_check_official_presets()
	_check_corrupt_resource()
	_check_duplicate_id()
	_check_missing_directory()
	await _check_apply_preset_in_main_scene()
	_reset_fixture_root()
	if failures.is_empty():
		print("PRESET_CATALOG_RESULT: PASS checks=%d" % checks_run)
		get_tree().quit(0)
	else:
		for failure in failures:
			printerr("PRESET_CATALOG_FAIL: %s" % failure)
		print("PRESET_CATALOG_RESULT: FAIL count=%d checks=%d" % [failures.size(), checks_run])
		get_tree().quit(1)

func _check(condition: bool, label: String) -> void:
	checks_run += 1
	if condition:
		print("  ok - %s" % label)
	else:
		failures.append(label)
		printerr("  FAIL - %s" % label)

func _reset_fixture_root() -> void:
	_remove_recursive(FIXTURE_ROOT)

func _remove_recursive(path: String) -> void:
	var dir := DirAccess.open(path)
	if dir == null:
		return
	dir.list_dir_begin()
	var name := dir.get_next()
	while not name.is_empty():
		var child := path.path_join(name)
		if dir.current_is_dir():
			_remove_recursive(child)
		else:
			dir.remove(name)
		name = dir.get_next()
	dir.list_dir_end()
	dir.remove(path)

func _make_fixture_dir(sub: String) -> String:
	var path := FIXTURE_ROOT.path_join(sub)
	DirAccess.make_dir_recursive_absolute(path)
	return path

func _save_fixture_preset(path: String, id: String, display_name: String) -> void:
	var preset: PipePreset = PipePresetScript.new()
	preset.id = id
	preset.display_name = display_name
	preset.diameter = 0.2
	preset.diameter_profile = [{"end": 1.0, "diameter": 0.2}]
	preset.radial_segments = 16
	preset.default_corner_segments = 8
	var err := ResourceSaver.save(preset, path)
	_check(err == OK, "夹具预设写入成功：%s" % path)

func _write_corrupt_file(path: String) -> void:
	var file := FileAccess.open(path, FileAccess.WRITE)
	file.store_string("this is not a Godot resource")
	file.close()

func _load_catalog(dir: String) -> PipePresetCatalog:
	var catalog: PipePresetCatalog = PresetCatalogScript.new()
	catalog.directory = dir
	catalog.load_all()
	return catalog

func _check_official_presets() -> void:
	print("[1] 正式预设目录全量加载")
	var catalog := _load_catalog(PipePresetCatalog.DEFAULT_DIRECTORY)
	_check(catalog.errors.is_empty(), "正式预设加载无错误（实际：%s）" % str(catalog.errors))
	_check(catalog.definitions.size() == OFFICIAL_PRESET_IDS.size(),
		"正式预设数量为 %d（实际 %d）" % [OFFICIAL_PRESET_IDS.size(), catalog.definitions.size()])
	var ids := {}
	for entry in catalog.definitions:
		ids[String(entry["preset"].id)] = true
	for expected in OFFICIAL_PRESET_IDS:
		_check(ids.has(expected), "正式预设包含 id=%s" % expected)
	var sorted_ok := true
	for i in range(1, catalog.definitions.size()):
		var previous: PipePreset = catalog.definitions[i - 1]["preset"]
		var current: PipePreset = catalog.definitions[i]["preset"]
		sorted_ok = sorted_ok and previous.display_name <= current.display_name
	_check(sorted_ok, "预设按 display_name 升序排列")
	for entry in catalog.definitions:
		_check(String(entry["path"]).ends_with(".tres"), "预设条目记录来源路径：%s" % entry["path"])

func _check_corrupt_resource() -> void:
	print("[2] 损坏资源记入错误且不阻塞其余预设")
	var dir := _make_fixture_dir("corrupt")
	_save_fixture_preset(dir.path_join("good.tres"), "fixture_good", "夹具良好预设")
	_write_corrupt_file(dir.path_join("broken.tres"))
	var catalog := _load_catalog(dir)
	_check(catalog.definitions.size() == 1, "损坏资源被跳过，良好预设仍加载（实际 %d 条）" % catalog.definitions.size())
	_check(catalog.errors.size() == 1, "损坏资源记入 1 条错误（实际 %d 条）" % catalog.errors.size())
	if catalog.errors.size() == 1:
		_check(catalog.errors[0].contains("broken.tres"), "错误信息指向损坏文件：%s" % catalog.errors[0])

func _check_duplicate_id() -> void:
	print("[3] 重复 ID 拒绝")
	var dir := _make_fixture_dir("duplicate")
	_save_fixture_preset(dir.path_join("first.tres"), "fixture_dup", "夹具重复甲")
	_save_fixture_preset(dir.path_join("second.tres"), "fixture_dup", "夹具重复乙")
	var catalog := _load_catalog(dir)
	_check(catalog.definitions.size() == 1, "重复 ID 只保留首个（实际 %d 条）" % catalog.definitions.size())
	_check(catalog.errors.size() == 1, "重复 ID 记入 1 条错误（实际 %d 条）" % catalog.errors.size())
	if catalog.errors.size() == 1:
		_check(catalog.errors[0].contains("重复"), "错误信息说明重复：%s" % catalog.errors[0])
	if catalog.definitions.size() == 1:
		_check(String(catalog.definitions[0]["path"]).ends_with("first.tres"), "保留按文件名排序后的首个文件")

func _check_missing_directory() -> void:
	print("[4] 缺失目录错误")
	var missing := FIXTURE_ROOT.path_join("does_not_exist")
	_check(not DirAccess.dir_exists_absolute(missing), "夹具目录确实不存在：%s" % missing)
	var catalog := _load_catalog(missing)
	_check(catalog.definitions.is_empty(), "缺失目录不产生预设条目")
	_check(catalog.errors.size() == 1, "缺失目录记入 1 条错误（实际 %d 条）" % catalog.errors.size())
	if catalog.errors.size() == 1:
		_check(catalog.errors[0].contains("不存在"), "错误信息说明目录缺失：%s" % catalog.errors[0])

func _check_apply_preset_in_main_scene() -> void:
	print("[5] 真实 main 场景应用预设：网格参数/顶点数与材质变化")
	var main: Node3D = MainScene.instantiate()
	add_child(main)
	await get_tree().process_frame
	await get_tree().physics_frame
	if main.pipe_root.get_child_count() == 0:
		# 物理空间未就绪时兜底重试一次，避免时序假阴性（与 smoke 一致）。
		await get_tree().physics_frame
		main._create_demo_pipe()
	_check(main.control_points.size() >= 2, "main 场景示例管道已生成")
	var catalog := _load_catalog(PipePresetCatalog.DEFAULT_DIRECTORY)
	var index := -1
	for i in catalog.definitions.size():
		if catalog.definitions[i]["preset"].radial_segments != BASELINE_RADIAL_SEGMENTS:
			index = i
			break
	_check(index >= 0, "存在环向分段不同于基线 %d 的预设" % BASELINE_RADIAL_SEGMENTS)
	if index < 0:
		main.queue_free()
		return
	var preset: PipePreset = catalog.get_preset(index)
	var vertex_count_before: int = main.generated_vertex_count
	var tint_before: Color = main.pipe_material.get_shader_parameter("tint")
	main._apply_preset_to_selection(index)
	_check(main.radial_segments == preset.radial_segments,
		"应用预设后 radial_segments=%d（预期 %d）" % [main.radial_segments, preset.radial_segments])
	_check(main.default_corner_segments == preset.default_corner_segments,
		"应用预设后 default_corner_segments=%d（预期 %d）" % [main.default_corner_segments, preset.default_corner_segments])
	_check(main.segments.size() == preset.diameter_profile.size() and not main.segments.is_empty(),
		"应用预设后管径分段与预设一致（%d 段）" % main.segments.size())
	if not main.segments.is_empty():
		_check(is_equal_approx(float(main.segments[0]["diameter"]), float(preset.diameter_profile[0]["diameter"])),
			"首段管径与预设一致（%.3f）" % float(main.segments[0]["diameter"]))
	_check(main.generated_vertex_count != vertex_count_before,
		"顶点数随预设变化（%d -> %d）" % [vertex_count_before, main.generated_vertex_count])
	var tint_after: Color = main.pipe_material.get_shader_parameter("tint")
	_check(tint_after == preset.tint and tint_after != tint_before,
		"材质 tint 切换为预设值 %s" % str(tint_after))
	main.queue_free()
	await get_tree().process_frame
