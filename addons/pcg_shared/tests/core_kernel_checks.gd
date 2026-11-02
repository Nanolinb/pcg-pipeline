class_name PCGCoreKernelChecks
extends RefCounted

# v0.14 公共内核专项测试（docs/core_contracts.md §1/§3/§5/§6，验收 T3/T4/T7/T8）。
# 单源随共享包分发；spike_check.gd（三消费者入口）与
# tests/core_kernel_check.gd（独立 -s 入口）都调用 run()。
#
# 黄金向量：
# - RNG 派生种子（SHA256("pcg-rng/v1\n"+master+"\n"+key) 前 8 字节小端）；
# - v1 旧格式文档逐级迁移后的 payload 规范化语义哈希。

const LOG_PREFIX := "KERNEL"

# --- RNG 黄金向量（派生方案 v1，SHA256 前 8 字节小端；int64 位等价表示） ---
const GOLDEN_SEED_MASTER42_W1 := -6724053372761431311  # u64 11722690700948120305
const GOLDEN_SEED_MASTER42_W1_D7 := -738261074153563535  # u64 17708482999555988081
const GOLDEN_SEED_ASSEMBLY_LAYOUT := 7619144496807824136  # seed_a + assembly=a3/purpose=layout

# --- 迁移黄金回归：v1 文档逐级迁移到 v3 后的 payload 语义哈希 ---
const GOLDEN_MIGRATED_PAYLOAD_HASH := "571cf140f31af906406f9aa9241ee2b4cd566c06d6e982d6e69f4fcf9e7ec4a4"

# 保留的旧版（v1）测试文档原文，迁移语义变更必须通过黄金哈希回归审核。
const LEGACY_DOC_V1 := """
{
  "format_version": 1,
  "app_version": "0.13.0",
  "payload": {
    "kind": "wall",
    "label": "front"
  }
}
"""

var checks_run: int = 0
var failures: Array[String] = []
var _prefix: String = LOG_PREFIX


func run(log_prefix: String = LOG_PREFIX) -> Dictionary:
	_prefix = log_prefix
	_check_stable_id()
	_check_format_migration()
	_check_canonical_serialization()
	_check_rebuild_signature()
	_check_deterministic_rng()
	_check_atomic_store()
	return {"checks_run": checks_run, "failures": failures.duplicate()}


func _record(ok: bool, name: String, detail: String = "") -> void:
	checks_run += 1
	var label := name + ("" if detail.is_empty() else " (" + detail + ")")
	if ok:
		print("%s_CHECK_PASS: %s" % [_prefix, label])
	else:
		failures.append(label)
		print("%s_CHECK_FAIL: %s" % [_prefix, label])


# ---------------------------------------------------------------- 稳定 ID

func _check_stable_id() -> void:
	var generated: Array[String] = []
	var all_valid := true
	var unique := true
	for index in 64:
		var stable := PCGStableId.generate(&"cmp")
		all_valid = all_valid and stable.is_valid_id()
		if generated.has(String(stable.id)):
			unique = false
		generated.append(String(stable.id))
	_record(all_valid, "stable id: generated ids validate", "pattern [a-z0-9_-]+")
	_record(unique, "stable id: generated ids unique", "%d samples" % generated.size())

	var stable := PCGStableId.generate(&"cmp")
	stable.created_with = "0.14.0-test"
	stable.display_name = "Facade A"
	var before: Dictionary = stable.signature_fields()
	var renamed := PCGStableId.new()
	renamed.id = stable.id
	renamed.display_name = "完全不同的显示名"
	_record(before == stable.signature_fields()
		and stable.signature_fields() == renamed.signature_fields(),
		"stable id: audit/display fields excluded from signature")

	stable.display_name = "Facade A"
	var twin := PCGStableId.new()
	_record(twin.from_dict(stable.to_dict()).is_empty() and twin.id == stable.id
		and twin.display_name == "Facade A", "stable id: to_dict/from_dict round-trip")

	var broken := PCGStableId.new()
	var bad := {"id": "Bad ID", "id_version": 1}
	var problems := broken.from_dict(bad)
	_record(not problems.is_empty() and broken.id == &"",
		"stable id: invalid id rejected without half-built state", problems[0] if not problems.is_empty() else "")
	var future := PCGStableId.new()
	problems = future.from_dict({"id": "cmp_ok", "id_version": 99})
	_record(not problems.is_empty() and future.id == &"",
		"stable id: future id schema rejected", problems[0] if not problems.is_empty() else "")


# ---------------------------------------------------------------- 格式迁移

func _build_migrator() -> PCGFormatMigrator:
	# 演示格式 v1→v3：新字段以追加方式加入并提供默认值；重命名必须提升格式版本。
	var migrator := PCGFormatMigrator.new(3)
	migrator.add_migration(1, func(document: Dictionary, _from_version: int) -> Dictionary:
		var payload: Dictionary = document["payload"]
		payload["display_label"] = payload.get("label", "")
		payload.erase("label")
		payload["width"] = payload.get("width", 1.0)  # 追加字段，默认值
		document["payload"] = payload
		document["format_version"] = 2
		return document)
	migrator.add_migration(2, func(document: Dictionary, _from_version: int) -> Dictionary:
		var payload: Dictionary = document["payload"]
		payload["flags"] = payload.get("flags", [])
		document["payload"] = payload
		document["format_version"] = 3
		return document)
	migrator.set_payload_validator(func(payload: Dictionary) -> Array[String]:
		var problems: Array[String] = []
		if not ["wall", "window"].has(String(payload.get("kind", ""))):
			problems.append("payload.kind must be wall or window")
		if float(payload.get("width", 0.0)) <= 0.0:
			problems.append("payload.width must be positive")
		return problems)
	return migrator


func _check_format_migration() -> void:
	var migrator := _build_migrator()
	var loaded := migrator.parse_document(LEGACY_DOC_V1)
	if not loaded["ok"]:
		_record(false, "migration: legacy v1 document loads", String("; ".join(loaded["errors"])))
		return
	var document: Dictionary = loaded["document"]
	var payload: Dictionary = document["payload"]
	_record(document["format_version"] == 3 and document["app_version"] == "0.13.0",
		"migration: envelope survives stepwise migration", "format_version=%d" % document["format_version"])
	_record(payload.get("display_label") == "front" and not payload.has("label"),
		"migration: rename applied exactly once")
	_record(is_equal_approx(float(payload.get("width", 0.0)), 1.0) and payload.get("flags") is Array,
		"migration: appended fields have defaults")

	var migrated_hash := PCGCanonicalSerializer.hash_document(payload)
	_record(migrated_hash == GOLDEN_MIGRATED_PAYLOAD_HASH,
		"migration: golden regression hash stable", migrated_hash.substr(0, 16))

	var future := migrator.parse_document('{"format_version": 999, "app_version": "9.9.9", "payload": {}}')
	_record(not future["ok"] and String("; ".join(future["errors"])).contains("newer"),
		"migration: future format_version rejected with readable error",
		String("; ".join(future["errors"])).substr(0, 60))

	var gap := PCGFormatMigrator.new(3)
	gap.add_migration(1, func(document: Dictionary, _v: int) -> Dictionary:
		document["format_version"] = 2
		return document)
	var gap_result := gap.parse_document(LEGACY_DOC_V1)
	_record(not gap_result["ok"]
		and String("; ".join(gap_result["errors"])).contains("no migration registered from format_version 2"),
		"migration: missing step reports exact version gap",
		String("; ".join(gap_result["errors"])).substr(0, 60))

	var invalid := migrator.parse_document(
		'{"format_version": 1, "app_version": "0.13.0", "payload": {"kind": "bogus", "label": "x"}}')
	_record(not invalid["ok"] and not (invalid["errors"] as PackedStringArray).is_empty()
		and (invalid["document"] as Dictionary).is_empty(),
		"migration: validation failure lists field errors, no half document",
		String("; ".join(invalid["errors"])).substr(0, 60))

	var roundtrip := migrator.parse_document(
		JSON.stringify(migrator.save_document(payload, "0.14.0")))
	_record(roundtrip["ok"] and (roundtrip["document"]["payload"] as Dictionary) == payload,
		"migration: current-version document round-trips")


# ---------------------------------------------------------------- 规范化序列化

func _check_canonical_serialization() -> void:
	var enc := PCGCanonicalSerializer
	_record(enc.encode_float(1.0) == enc.encode_float(1.0000001)
		and enc.encode_float(1.0) != enc.encode_float(1.00001),
		"canonical: 1e-5 quantization boundary (T7)",
		"%s / %s / %s" % [enc.encode_float(1.0), enc.encode_float(1.0000001), enc.encode_float(1.00001)])
	_record(enc.encode_float(1.0) == "1.00000" and enc.encode_float(0.5) == "0.50000",
		"canonical: floats are fixed-point text, no %g/exponent")

	var dict_a := {"beta": 2, "alpha": 1}
	var dict_b := {"alpha": 1, "beta": 2}
	_record(enc.hash_document(dict_a) == enc.hash_document(dict_b),
		"canonical: dictionary keys sorted, insertion order irrelevant")
	_record(enc.hash_document({"items": [1, 2]}) != enc.hash_document({"items": [2, 1]}),
		"canonical: array order preserved")
	_record(enc.encode([1, 2]).begins_with("[2]("),
		"canonical: array length recorded")
	_record(enc.encode(0.123456789) == "0.12346",
		"canonical: nested float quantized to 1e-5")
	_record(enc.hash_document({"v": 1.0}) == enc.hash_document({"v": 1.0000001}),
		"canonical: semantic hash ignores sub-1e-5 float noise")


# ---------------------------------------------------------------- 重建签名

func _check_rebuild_signature() -> void:
	var host := {"host_size": [4.0, 3.0]}
	var params := {"user_scale": 1.0, "neighborhood_scale": 2.0}
	var s1 := PCGRebuildSignature.from_inputs(&"transition_mesh/v1", 1, host, params)
	var s2 := PCGRebuildSignature.from_inputs(&"transition_mesh/v1", 1, host, params)
	_record(s1.digest == s2.digest and s1.cache_key() == s1.digest,
		"signature: identical inputs give identical cache key (T6 hit)")

	var changed_param := PCGRebuildSignature.from_inputs(&"transition_mesh/v1", 1, host,
		{"user_scale": 1.00001, "neighborhood_scale": 2.0})
	var changed_host := PCGRebuildSignature.from_inputs(&"transition_mesh/v1", 1,
		{"host_size": [4.0, 3.00001]}, params)
	_record(s1.digest != changed_param.digest, "signature: param change invalidates digest")
	_record(s1.digest != changed_host.digest, "signature: host geometry change invalidates digest")

	var seeded := PCGRebuildSignature.from_inputs(&"transition_mesh/v1", 1, host, params,
		PCGDeterministicRng.create_stream("master42", {"world": "w1"}).seed_info())
	var seeded_other_scope := PCGRebuildSignature.from_inputs(&"transition_mesh/v1", 1, host, params,
		PCGDeterministicRng.create_stream("master42", {"world": "w2"}).seed_info())
	_record(s1.seed_digest.is_empty() and not seeded.seed_digest.is_empty()
		and seeded.seed_digest != seeded_other_scope.digest and seeded.digest != s1.digest
		and seeded.digest != seeded_other_scope.digest,
		"signature: seed digest written only when random used, scope-sensitive")

	var reloaded := PCGRebuildSignature.new()
	_record(reloaded.from_dict(s1.to_dict()).is_empty() and reloaded.digest == s1.digest,
		"signature: to_dict/from_dict round-trip")
	_record(s1.recalculate() == s1.digest, "signature: recalculate deterministic")


# ---------------------------------------------------------------- 确定性随机

func _check_deterministic_rng() -> void:
	var rng := PCGDeterministicRng
	_record(rng.derive_stream_seed("master42", "world=w1") == GOLDEN_SEED_MASTER42_W1
		and rng.derive_stream_seed("master42", "world=w1/district=d7") == GOLDEN_SEED_MASTER42_W1_D7
		and rng.derive_stream_seed("seed_a", "assembly=a3/purpose=layout") == GOLDEN_SEED_ASSEMBLY_LAYOUT,
		"rng: derivation v1 golden seeds (SHA256 first 8 bytes)")

	var scope := {"world": "w1", "district": "d7"}
	var stream_a := rng.create_stream("master42", scope)
	var stream_b := rng.create_stream("master42", {"district": "d7", "world": "w1"})
	var identical := true
	for index in 1000:
		if stream_a.randf() != stream_b.randf():
			identical = false
			break
	_record(identical, "rng: 1000 repeated draws deterministic (T4)")

	# A/B 隔离：创建并采样别的流，不改变 B 的序列。
	var b_reference := rng.create_stream("master42", {"world": "w1", "purpose": "layout"})
	var expected: Array[float] = []
	for index in 64:
		expected.append(b_reference.randf())
	var interferer := rng.create_stream("master99", {"world": "w1", "purpose": "layout"})
	for index in 128:
		interferer.randf()
	rng.create_stream("master42", {"world": "w1", "purpose": "appearance"}).randf()
	var b_again := rng.create_stream("master42", {"world": "w1", "purpose": "layout"})
	var isolated := true
	for index in 64:
		if b_again.randf() != expected[index]:
			isolated = false
			break
	_record(isolated, "rng: branch A activity does not change branch B sequence")

	# 追加作用域不改变旧流：独立 RNG + 纯派生函数，旧键文本稳定。
	_record(rng.normalize_scope_key({"district": "d7", "world": "w1"}) == "world=w1/district=d7",
		"rng: normalized scope key stable regardless of insertion order")
	var old_key := rng.normalize_scope_key({"world": "w1"})
	_record(old_key == "world=w1"
		and rng.derive_stream_seed("master42", old_key) == GOLDEN_SEED_MASTER42_W1,
		"rng: appended scopes do not alter existing stream derivation")

	var problems := rng.validate_scope({"world": "w1", "purpose": "bogus"})
	var purpose_problems := rng.validate_scope({"assembly": "a1"})
	_record(not problems.is_empty() and purpose_problems.is_empty(),
		"rng: purpose values extend by append, unknown purpose rejected")

	var info := stream_a.seed_info()
	_record(info["master_seed"] == "master42" and int(info["derivation_version"]) == 1
		and info["scope"] == "world=w1/district=d7",
		"rng: master seed, derivation version and scope recoverable")


# ---------------------------------------------------------------- 原子保存

func _check_atomic_store() -> void:
	var store := PCGAtomicStore.new()
	store.content_validator = func(content: String) -> Array[String]:
		var problems: Array[String] = []
		var json := JSON.new()
		if json.parse(content) != OK or not (json.data is Dictionary) or not json.data.has("version"):
			problems.append("document is not a valid versioned JSON object")
		return problems
	var dir := "user://pcg_kernel_atomic_test"
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(dir))
	var path := dir + "/doc.json"
	for suffix in ["", PCGAtomicStore.TEMP_SUFFIX, PCGAtomicStore.BACKUP_SUFFIX]:
		DirAccess.remove_absolute(ProjectSettings.globalize_path(path + suffix))

	var content1 := '{"version": 1, "items": [1, 2]}'
	var content2 := '{"version": 2, "items": [1, 2, 3]}'
	var content3 := '{"version": 3, "items": []}'
	_record(store.save(path, content1)["ok"], "atomic: first save commits")
	_record(FileAccess.get_file_as_string(path) == content1,
		"atomic: formal file content exact")

	var second: Dictionary = store.save(path, content2)
	_record(second["ok"] and FileAccess.get_file_as_string(path + PCGAtomicStore.BACKUP_SUFFIX) == content1,
		"atomic: previous formal kept as .bak1 before replace")

	var commit_failure: Dictionary = store.save(path, content3, "before_commit")
	_record(not commit_failure["ok"] and FileAccess.get_file_as_string(path) == content2,
		"atomic: failed commit never falls back to non-atomic overwrite")

	var interrupted: Dictionary = store.save(path, content3, "after_temp_write")
	var state: Dictionary = store.inspect(path)
	_record(not interrupted["ok"] and interrupted["fault"] == "after_temp_write"
		and FileAccess.get_file_as_string(path) == content2 and state["temp_exists"],
		"atomic: injected interruption leaves formal intact with temp residue")

	var recovered: Dictionary = store.recover(path)
	var after_cleanup: Dictionary = store.inspect(path)
	_record(recovered["action"] == "cleaned_temp" and after_cleanup["temp_exists"] == false
		and FileAccess.get_file_as_string(path) == content2,
		"atomic: stale temp cleaned without touching formal data (T3)")

	var corrupt := FileAccess.open(path, FileAccess.WRITE)
	corrupt.store_string("{ not json")
	corrupt.close()
	var prompt: Dictionary = store.recover(path)
	_record(prompt["action"] == "needs_recovery"
		and not String(prompt["recovery_prompt"]).is_empty()
		and FileAccess.get_file_as_string(path) == "{ not json",
		"atomic: corrupt formal triggers recovery prompt, no silent overwrite")
	var confirmed: Dictionary = store.recover(path, true)
	_record(confirmed["action"] == "restored_backup"
		and FileAccess.get_file_as_string(path) == content2 and store.is_formal_valid(path),
		"atomic: user-confirmed restore returns last consistent data")

	var healthy: Dictionary = store.recover(path)
	_record(healthy["action"] == "none", "atomic: healthy file needs no action")

	for suffix in ["", PCGAtomicStore.TEMP_SUFFIX, PCGAtomicStore.BACKUP_SUFFIX]:
		DirAccess.remove_absolute(ProjectSettings.globalize_path(path + suffix))
