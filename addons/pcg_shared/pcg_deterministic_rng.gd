class_name PCGDeterministicRng
extends RefCounted

# v0.14 公共内核：确定性随机流派生（docs/core_contracts.md §3），方案版本 1。
#
#   stream_key  = 规范化作用域路径（仅按 SCOPE_KEYS 固定顺序取存在的键）
#   stream_seed = SHA256("pcg-rng/v1\n" + master_seed + "\n" + stream_key) 的前 8 字节（小端 u64）
#
# - 每个作用域使用独立 RandomNumberGenerator（PCGRandomStream），业务代码禁止
#   调用全局随机状态；同流内采样顺序属于生成行为。
# - SCOPE_KEYS 只允许追加键，不改变既有键的文本和派生算法。
# - purpose 合法值以追加方式扩展（KNOWN_PURPOSES），不改变既有用途含义。

const DERIVATION_VERSION := 1
const DERIVATION_PREFIX := "pcg-rng/v1"
const SEED_BYTE_COUNT := 8

# 追加顺序即契约顺序；只允许在末尾追加新键。
const SCOPE_KEYS: Array[StringName] = [
	&"world", &"district", &"parcel", &"building", &"assembly", &"purpose",
]

# 追加式扩展，不改变既有用途含义。
const KNOWN_PURPOSES: Array[StringName] = [
	&"layout", &"appearance", &"detail", &"variant",
]


static func validate_scope(scope: Dictionary) -> Array[String]:
	var problems: Array[String] = []
	for key in scope.keys():
		if not SCOPE_KEYS.has(StringName(key)):
			problems.append("unknown scope key: %s" % String(key))
	if scope.has("purpose"):
		var purpose := StringName(scope["purpose"])
		if not KNOWN_PURPOSES.has(purpose):
			problems.append("unknown purpose: %s" % String(purpose))
	return problems


static func normalize_scope_key(scope: Dictionary) -> String:
	# 只按 SCOPE_KEYS 固定顺序收录存在的键；忽略未知键和插入顺序，
	# 因此未来追加新作用域键不会改变既有键的规范化文本。
	var parts: Array[String] = []
	for key in SCOPE_KEYS:
		if scope.has(key):
			parts.append("%s=%s" % [String(key), str(scope[key])])
	return String("/").join(PackedStringArray(parts))


static func derive_stream_seed(master_seed: String, stream_key: String) -> int:
	var material := "%s\n%s\n%s" % [DERIVATION_PREFIX, master_seed, stream_key]
	var bytes := material.sha256_buffer()
	var seed := 0
	for index in SEED_BYTE_COUNT:
		seed |= int(bytes[index]) << (8 * index)
	return seed


static func create_stream(master_seed: String, scope: Dictionary) -> PCGRandomStream:
	var stream_key := normalize_scope_key(scope)
	var stream_seed := derive_stream_seed(master_seed, stream_key)
	return PCGRandomStream.new(master_seed, DERIVATION_VERSION, stream_key, stream_seed)
