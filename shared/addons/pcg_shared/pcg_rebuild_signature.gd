@tool
class_name PCGRebuildSignature
extends Resource

# v0.14 公共内核：重建签名（docs/core_contracts.md §5.2）。
# 缓存键为 digest；同签名命中，任一有效输入变化都必须失效。
# generator_version 在生成语义变化时递增，与文档格式版本分开。

const FORMAT_VERSION := 1

@export var generator_id: StringName = &""
@export var generator_version: int = 1
@export var host_signature: String = ""
@export var param_digest: String = ""
@export var seed_digest: String = ""
@export var digest: String = ""


static func from_inputs(p_generator_id: StringName, p_generator_version: int,
		host_inputs: Dictionary, params: Dictionary, seed_info: Dictionary = {}) -> PCGRebuildSignature:
	var signature := PCGRebuildSignature.new()
	signature.generator_id = p_generator_id
	signature.generator_version = p_generator_version
	# host_signature 只包含会影响结果的主体几何输入。
	signature.host_signature = "" if host_inputs.is_empty() \
		else PCGCanonicalSerializer.hash_document(host_inputs)
	signature.param_digest = PCGCanonicalSerializer.hash_document(params)
	# 使用随机时写入派生种子摘要，否则为空。
	signature.seed_digest = "" if seed_info.is_empty() \
		else PCGCanonicalSerializer.hash_document(seed_info)
	signature.recalculate()
	return signature


func recalculate() -> String:
	digest = PCGCanonicalSerializer.hash_document({
		"format_version": FORMAT_VERSION,
		"generator_id": String(generator_id),
		"generator_version": generator_version,
		"host_signature": host_signature,
		"param_digest": param_digest,
		"seed_digest": seed_digest,
	})
	return digest


func cache_key() -> String:
	return digest


func to_dict() -> Dictionary:
	return {
		"format_version": FORMAT_VERSION,
		"generator_id": String(generator_id),
		"generator_version": generator_version,
		"host_signature": host_signature,
		"param_digest": param_digest,
		"seed_digest": seed_digest,
		"digest": digest,
	}


func from_dict(data: Dictionary) -> Array[String]:
	var problems: Array[String] = []
	if not data.has("digest") or String(data.get("digest", "")).is_empty():
		problems.append("missing field: digest")
	if int(data.get("format_version", 0)) > FORMAT_VERSION:
		problems.append("signature format too new: %d" % int(data.get("format_version", 0)))
	if problems.is_empty():
		generator_id = StringName(data.get("generator_id", ""))
		generator_version = int(data.get("generator_version", 1))
		host_signature = String(data.get("host_signature", ""))
		param_digest = String(data.get("param_digest", ""))
		seed_digest = String(data.get("seed_digest", ""))
		digest = String(data.get("digest", ""))
	return problems
