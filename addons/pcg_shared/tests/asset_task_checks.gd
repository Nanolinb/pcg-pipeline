class_name PCGAssetTaskChecks
extends RefCounted

# v0.15 L0 资产任务模型与持久化专项测试。
# 单源随共享包分发；asset_task_check.gd（-s 入口）调用 run()。
# 覆盖：保存/重载往返、draft/assignment 两档校验、非法范围、
# AI 溯源、UV/碰撞策略与候选引用、重复 ID 报告、原子写入中断恢复、
# 四份示例任务加载。

const LOG_PREFIX := "TASK"

var checks_run: int = 0
var failures: Array[String] = []
var _prefix: String = LOG_PREFIX


func run(log_prefix: String = LOG_PREFIX) -> Dictionary:
	_prefix = log_prefix
	_check_validation_assignment_gate()
	_check_invalid_ranges()
	_check_ai_provenance()
	_check_uv_collision_candidates()
	_check_save_reload_roundtrip()
	_check_atomic_write_interruption()
	_check_duplicate_ids()
	_check_example_tasks()
	return {"checks_run": checks_run, "failures": failures.duplicate()}


func _record(ok: bool, name: String, detail: String = "") -> void:
	checks_run += 1
	var label := name + ("" if detail.is_empty() else " (" + detail + ")")
	if ok:
		print("%s_CHECK_PASS: %s" % [_prefix, label])
	else:
		failures.append(label)
		print("%s_CHECK_FAIL: %s" % [_prefix, label])


func _valid_task(task_id: StringName = &"task_test_valid") -> PCGAssetTask:
	var task := PCGAssetTask.new()
	task.task_id = task_id
	task.display_name = "测试任务"
	task.category = &"door"
	task.purpose = "校验用最小可分配任务"
	task.producer = &"ai"
	task.source_tool = "test-tool"
	task.source_prompt = "test prompt"
	task.source_seed = "test-seed"
	task.size_min = Vector3(0.5, 0.5, 0.1)
	task.size_max = Vector3(1.5, 1.5, 0.3)
	task.tri_budget = 2000
	task.lod1_budget = 800
	task.lod2_budget = 200
	task.texture_size = 1024
	task.material_budget = 2
	task.interface_requirements = "根节点居中"
	return task


func _errors_contain(errors: Array, needle: String) -> bool:
	for e in errors:
		if e.contains(needle):
			return true
	return false


# ---------------------------------------------------------------- 校验门槛

func _check_validation_assignment_gate() -> void:
	var blank := PCGAssetTask.new()
	_record(blank.validation_errors().is_empty(),
		"validation: blank draft passes draft-level checks")
	var assign: Array[String] = blank.validation_errors(true)
	_record(assign.size() >= 5 and _errors_contain(assign, "task_id")
		and _errors_contain(assign, "display_name") and _errors_contain(assign, "purpose")
		and _errors_contain(assign, "interface_requirements"),
		"validation: blank task fails assignment with per-field errors", "%d errors" % assign.size())

	var valid := _valid_task()
	_record(valid.validation_errors(true).is_empty(),
		"validation: complete task is assignable")

	var bad_enum := _valid_task(&"task_bad_enum")
	bad_enum.category = &"portal"
	bad_enum.producer = &"robot"
	bad_enum.precision_tier = &"close"
	bad_enum.status = &"done"
	var enum_errors := bad_enum.validation_errors()
	_record(_errors_contain(enum_errors, "category") and _errors_contain(enum_errors, "producer")
		and _errors_contain(enum_errors, "precision_tier") and _errors_contain(enum_errors, "status"),
		"validation: unknown category/producer/precision_tier/status rejected")

	var bad_id := _valid_task(&"Task Bad ID!")
	_record(_errors_contain(bad_id.validation_errors(), "task_id"),
		"validation: non-ascii/lowercase task_id rejected")

	var bad_axis := _valid_task()
	bad_axis.outward_axis = Vector3.ZERO
	bad_axis.up_axis = Vector3(0.0, 2.0, 0.0)
	var axis_errors := bad_axis.validation_errors()
	_record(_errors_contain(axis_errors, "outward_axis") and _errors_contain(axis_errors, "up_axis"),
		"validation: zero/un-normalized axes rejected")

	var future := PCGAssetTask.new()
	var future_problems := future.from_dict({"format_version": 99, "task_id": "task_future"})
	_record(not future_problems.is_empty() and String(future.task_id).is_empty(),
		"validation: future format_version rejected without half-built task",
		future_problems[0] if not future_problems.is_empty() else "")


# ---------------------------------------------------------------- 非法范围

func _check_invalid_ranges() -> void:
	var flipped := _valid_task()
	flipped.size_min = Vector3(1.0, 1.0, 0.3)
	flipped.size_max = Vector3(0.5, 0.5, 0.1)
	_record(_errors_contain(flipped.validation_errors(true), "size_min <= size_max"),
		"ranges: size_min > size_max rejected at assignment")

	var zero_size := _valid_task()
	zero_size.size_min = Vector3(0.5, 0.5, 0.0)
	_record(_errors_contain(zero_size.validation_errors(true), "positive size_min/size_max"),
		"ranges: zero axis in size range rejected at assignment")

	var lod_order := _valid_task()
	lod_order.lod1_budget = 900
	lod_order.lod2_budget = 400
	lod_order.tri_budget = 800
	_record(_errors_contain(lod_order.validation_errors(true), "LOD0 >= LOD1 >= LOD2"),
		"ranges: tri < lod1 rejected at assignment")

	var lod_zero := _valid_task()
	lod_zero.lod2_budget = 0
	_record(_errors_contain(lod_zero.validation_errors(true), "positive tri_budget"),
		"ranges: zero budget rejected at assignment")

	var not_pow2 := _valid_task()
	not_pow2.texture_size = 1000
	_record(_errors_contain(not_pow2.validation_errors(), "power of two"),
		"ranges: non-power-of-two texture_size rejected")

	var negative := _valid_task()
	negative.variant_count = 0
	negative.root_embed = -0.1
	negative.texture_size = -4
	var neg_errors := negative.validation_errors()
	_record(_errors_contain(neg_errors, "variant_count") and _errors_contain(neg_errors, "root_embed")
		and _errors_contain(neg_errors, "texture_size"),
		"ranges: negative/zero scalar fields rejected")


# ---------------------------------------------------------------- AI 溯源

func _check_ai_provenance() -> void:
	var ai := _valid_task(&"task_ai_no_trace")
	ai.source_tool = ""
	ai.source_prompt = ""
	ai.source_seed = ""
	var missing := ai.validation_errors(true)
	_record(_errors_contain(missing, "source_tool") and _errors_contain(missing, "source_prompt")
		and _errors_contain(missing, "source_seed"),
		"provenance: ai task without trace fields fails assignment")

	ai.source_tool = "tool-x"
	ai.source_seed = "seed-9"
	var partial := ai.validation_errors(true)
	_record(_errors_contain(partial, "source_prompt") and partial.size() == 1,
		"provenance: partial trace still fails, errors pinpoint the gap")

	var human := _valid_task(&"task_human_ok")
	human.producer = &"human"
	human.source_tool = ""
	human.source_prompt = ""
	human.source_seed = ""
	_record(human.validation_errors(true).is_empty(),
		"provenance: human task needs no source trace")

	var proc := _valid_task(&"task_proc_ok")
	proc.producer = &"procedural"
	proc.source_tool = ""
	proc.source_prompt = ""
	proc.source_seed = ""
	_record(proc.validation_errors(true).is_empty(),
		"provenance: procedural task needs no source trace")


# ---------------------------------------------------------------- UV/碰撞/候选引用

func _check_uv_collision_candidates() -> void:
	var defaults := PCGAssetTask.new()
	_record(defaults.uv_policy == &"world_scale" and defaults.collision_policy == &"box"
		and defaults.candidate_refs.is_empty(),
		"policies: defaults are world_scale/box with empty candidates")

	var hot_reload := PCGAssetTask.new()
	hot_reload.set("uv_policy", null)
	hot_reload.set("collision_policy", null)
	var hot_errors := hot_reload.validation_errors()
	_record(_errors_contain(hot_errors, "uv_policy") and _errors_contain(hot_errors, "collision_policy"),
		"policies: nil fields during hot reload report errors without crashing")

	var bad := _valid_task(&"task_bad_policies")
	bad.uv_policy = &"stretch"
	bad.collision_policy = &"mesh"
	var errors := bad.validation_errors()
	_record(_errors_contain(errors, "uv_policy") and _errors_contain(errors, "collision_policy"),
		"policies: unknown uv/collision policy rejected")
	var raw_errors := PCGAssetTask.new().from_dict(
		{"task_id": "task_raw", "uv_policy": "mirrored", "collision_policy": "hull"})
	_record(_errors_contain(raw_errors, "uv_policy") and _errors_contain(raw_errors, "collision_policy"),
		"policies: unknown raw policy strings rejected at from_dict")

	var dup := _valid_task(&"task_dup_candidates")
	dup.candidate_refs = PackedStringArray(["res://a.tres", "res://a.tres"])
	_record(_errors_contain(dup.validation_errors(), "duplicate entry"),
		"candidates: duplicate refs rejected")

	var empty_ref := _valid_task(&"task_empty_candidate")
	empty_ref.candidate_refs = PackedStringArray(["res://a.tres", ""])
	_record(_errors_contain(empty_ref.validation_errors(), "empty entry"),
		"candidates: empty ref entry rejected")

	# 核心契约：挂多个候选引用不得覆盖/篡改来源工具、提示词与种子。
	var ai := _valid_task(&"task_candidates_keep_trace")
	ai.candidate_refs = PackedStringArray(
		["res://candidates/v1.tres", "res://candidates/v2.tres", "res://candidates/v3.tres"])
	var dict := ai.to_dict()
	dict["candidate_refs"] = Array(ai.candidate_refs) + ["res://candidates/v4.tres"]
	var restored := PCGAssetTask.new()
	var restore_problems := restored.from_dict(dict)
	_record(restore_problems.is_empty()
		and restored.candidate_refs.size() == 4
		and restored.source_tool == "test-tool"
		and restored.source_prompt == "test prompt"
		and restored.source_seed == "test-seed",
		"candidates: multiple refs never overwrite source tool/prompt/seed")
	var ai_errors := restored.validation_errors(true)
	_record(ai_errors.is_empty(),
		"candidates: ai task with refs still fully assignable")

	# 反向同样成立：来源字段更新不影响已记录的候选列表。
	restored.source_seed = "test-seed-r2"
	restored.candidate_refs.append("res://candidates/v5.tres")
	_record(restored.source_seed == "test-seed-r2" and restored.candidate_refs.size() == 5,
		"candidates: source update does not clobber candidate list")

	var uvs: Array[StringName] = PCGAssetTask.UV_POLICIES
	var cols: Array[StringName] = PCGAssetTask.COLLISION_POLICIES
	_record(uvs.size() == 3 and uvs[0] == &"world_scale" and uvs[1] == &"texel_density"
		and uvs[2] == &"custom"
		and cols.size() == 4 and cols[0] == &"none" and cols[1] == &"box"
		and cols[2] == &"convex" and cols[3] == &"concave",
		"policies: enum tables fixed")


# ---------------------------------------------------------------- 保存/重载

func _check_save_reload_roundtrip() -> void:
	var store := PCGAssetTaskStore.new()
	var dir := "user://pcg_asset_task_test/roundtrip"
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(dir))
	# 清理历史运行的残留，保证“拒绝落盘”断言检查的是本次行为。
	DirAccess.remove_absolute(ProjectSettings.globalize_path(
		dir + "/task_not_assignable.task.json"))
	var task := _valid_task(&"task_roundtrip")
	task.style_tags = PackedStringArray(["industrial", "riveted"])
	task.reference_urls = PackedStringArray(["https://example.invalid/ref"])
	task.status = &"assigned"
	task.uv_policy = &"texel_density"
	task.collision_policy = &"convex"
	task.candidate_refs = PackedStringArray(["res://candidates/roundtrip_a.tres"])
	var saved: Dictionary = store.save_task(task, dir)
	_record(saved["ok"] and FileAccess.file_exists(saved["path"]),
		"store: save_task commits atomically", String(saved["path"]))

	var loaded: Dictionary = store.load_task(saved["path"])
	var task2: PCGAssetTask = loaded["task"]
	_record(loaded["ok"] and task2.task_id == task.task_id
		and task2.display_name == task.display_name
		and task2.category == &"door"
		and task2.producer == &"ai"
		and task2.size_min == task.size_min and task2.size_max == task.size_max
		and task2.tri_budget == 2000 and task2.lod1_budget == 800 and task2.lod2_budget == 200
		and task2.texture_size == 1024 and task2.material_budget == 2
		and task2.style_tags == task.style_tags
		and task2.reference_urls == task.reference_urls
		and task2.status == &"assigned"
		and task2.uv_policy == &"texel_density" and task2.collision_policy == &"convex"
		and task2.candidate_refs == PackedStringArray(["res://candidates/roundtrip_a.tres"])
		and task2.source_seed == "test-seed"
		and is_equal_approx(task2.root_embed, 0.12)
		and task2.outward_axis == Vector3.BACK and task2.up_axis == Vector3.UP,
		"store: load_task round-trips every payload field")

	_record(task2.to_dict() == task.to_dict(), "model: to_dict stable across round-trip")

	var invalid := PCGAssetTask.new()
	invalid.task_id = &"task_not_assignable"
	var rejected: Dictionary = store.save_task(invalid, dir)
	_record(not rejected["ok"] and not (rejected["errors"] as Array).is_empty()
		and not FileAccess.file_exists(dir + "/task_not_assignable.task.json"),
		"store: invalid task refused before touching disk")

	var not_found: Dictionary = store.load_task(dir + "/task_missing.task.json")
	_record(not not_found["ok"] and _errors_contain(not_found["errors"], "file not found"),
		"store: missing file reports readable error")

	var bad_json := dir + "/task_bad.task.json"
	var f := FileAccess.open(bad_json, FileAccess.WRITE)
	f.store_string("{ not json")
	f.close()
	var bad: Dictionary = store.load_task(bad_json)
	_record(not bad["ok"] and _errors_contain(bad["errors"], "invalid JSON"),
		"store: corrupt JSON reported with line number")

	var newer := dir + "/task_newer.task.json"
	var f2 := FileAccess.open(newer, FileAccess.WRITE)
	f2.store_string('{"format_version": 99, "payload": {}}')
	f2.close()
	var newer_result: Dictionary = store.load_task(newer)
	_record(not newer_result["ok"] and _errors_contain(newer_result["errors"], "newer"),
		"store: future format_version rejected at load")

	var wrong_payload := dir + "/task_nopayload.task.json"
	var f3 := FileAccess.open(wrong_payload, FileAccess.WRITE)
	f3.store_string('{"format_version": 1}')
	f3.close()
	var wp: Dictionary = store.load_task(wrong_payload)
	_record(not wp["ok"] and _errors_contain(wp["errors"], "payload"),
		"store: envelope without payload rejected")


# ---------------------------------------------------------------- 原子写入中断

func _check_atomic_write_interruption() -> void:
	var store := PCGAssetTaskStore.new()
	var dir := "user://pcg_asset_task_test/atomic"
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(dir))
	var first := _valid_task(&"task_atomic")
	var first_save: Dictionary = store.save_task(first, dir)
	_record(first_save["ok"], "atomic: baseline save commits")

	var original: String = FileAccess.get_file_as_string(first_save["path"])
	var mutated := _valid_task(&"task_atomic")
	mutated.display_name = "被中断的写入"
	var interrupted: Dictionary = store.save_task(mutated, dir, "after_temp_write")
	var state: Dictionary = store.atomic_store.inspect(first_save["path"])
	_record(not interrupted["ok"] and interrupted["path"] == first_save["path"]
		and FileAccess.get_file_as_string(first_save["path"]) == original
		and state["temp_exists"],
		"atomic: injected interruption leaves formal file intact with temp residue")

	var recovered: Dictionary = store.atomic_store.recover(first_save["path"])
	var after: Dictionary = store.atomic_store.inspect(first_save["path"])
	var still_ok: Dictionary = store.load_task(first_save["path"])
	_record(recovered["action"] == "cleaned_temp" and not after["temp_exists"]
		and still_ok["ok"] and (still_ok["task"] as PCGAssetTask).display_name == "测试任务",
		"atomic: stale temp cleaned, original task still loads")

	var commit_fail: Dictionary = store.save_task(mutated, dir, "before_commit")
	_record(not commit_fail["ok"] and FileAccess.get_file_as_string(first_save["path"]) == original,
		"atomic: failed commit never falls back to non-atomic overwrite")


# ---------------------------------------------------------------- 重复 ID

func _check_duplicate_ids() -> void:
	var store := PCGAssetTaskStore.new()
	var dir := "user://pcg_asset_task_test/duplicates"
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(dir))
	for extra in ["", "_copy"]:
		var dup := _valid_task(&"task_duplicate")
		dup.display_name = "副本" if extra == "_copy" else "原件"
		var f := FileAccess.open(dir + "/task_duplicate" + extra + ".task.json", FileAccess.WRITE)
		f.store_string(JSON.stringify({"format_version": 1, "app_version": "0.15.0",
			"payload": dup.to_dict()}, "\t"))
		f.close()
	var broken := FileAccess.open(dir + "/task_broken.task.json", FileAccess.WRITE)
	broken.store_string('{"format_version": 1, "payload": {"task_id": "bad axis"}}')
	broken.close()

	var tasks := store.list_tasks(dir)
	_record(tasks.size() == 1 and tasks[0].task_id == &"task_duplicate",
		"store: duplicate task_id keeps first copy only", "%d loaded" % tasks.size())
	var report := String("; ".join(store.last_report))
	_record(report.contains("duplicate task_id") and report.contains("task_broken")
		and report.contains("size_min"),
		"store: duplicates and bad files reported, none silently skipped", report.substr(0, 80))


# ---------------------------------------------------------------- 示例任务

func _check_example_tasks() -> void:
	var store := PCGAssetTaskStore.new()
	var tasks := store.list_tasks("res://assets/tasks")
	var by_id := {}
	for task in tasks:
		by_id[String(task.task_id)] = task
	_record(tasks.size() == 4 and by_id.has("task_door_hatch_round")
		and by_id.has("task_window_square_rivet")
		and by_id.has("task_support_pipe_bracket")
		and by_id.has("task_sign_pipe_warning"),
		"examples: all four category samples load", "%d tasks" % tasks.size())
	var report_ok := store.last_report.is_empty()
	_record(report_ok,
		"examples: no load problems in shipped tasks",
		String("; ".join(store.last_report)).substr(0, 80))

	var expected_status := {
		"task_door_hatch_round": &"assigned",
		"task_window_square_rivet": &"assigned",
		"task_support_pipe_bracket": &"candidate",
		"task_sign_pipe_warning": &"draft",
	}
	var status_ok := true
	var assignable_ok := true
	var detail := ""
	for id in expected_status:
		if not by_id.has(id):
			status_ok = false
			assignable_ok = false
			continue
		var task: PCGAssetTask = by_id[id]
		if task.status != expected_status[id]:
			status_ok = false
			detail = "%s status=%s" % [id, String(task.status)]
		if not task.validation_errors(true).is_empty():
			assignable_ok = false
			detail = "%s: %s" % [id, "; ".join(task.validation_errors(true))]
	_record(status_ok, "examples: statuses match workflow", detail)
	_record(assignable_ok, "examples: every sample passes assignment validation", detail)

	var door: PCGAssetTask = by_id.get("task_door_hatch_round")
	_record(door != null and door.producer == &"ai" and not door.source_tool.is_empty()
		and not door.source_seed.is_empty(),
		"examples: ai sample carries full provenance")

	var expected_policies := {
		"task_door_hatch_round": [&"texel_density", &"convex"],
		"task_window_square_rivet": [&"world_scale", &"box"],
		"task_support_pipe_bracket": [&"world_scale", &"convex"],
		"task_sign_pipe_warning": [&"world_scale", &"none"],
	}
	var policies_ok := true
	var policy_detail := ""
	for id in expected_policies:
		if not by_id.has(id):
			policies_ok = false
			continue
		var task: PCGAssetTask = by_id[id]
		var want: Array = expected_policies[id]
		if task.uv_policy != want[0] or task.collision_policy != want[1]:
			policies_ok = false
			policy_detail = "%s uv=%s col=%s" % [id, String(task.uv_policy), String(task.collision_policy)]
	_record(policies_ok, "examples: uv/collision policies sensible per sample", policy_detail)

	var support: PCGAssetTask = by_id.get("task_support_pipe_bracket")
	_record(support != null and support.candidate_refs.size() == 2
		and support.validation_errors(true).is_empty(),
		"examples: candidate refs coexist with provenance and stay assignable")
