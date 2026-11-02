class_name PCGSharedMaterialCodec
extends RefCounted

# BASE-05 共享载体 Spike：资源持久化与确定性校验小工具。
# 证明共享模块可在任意消费者工程内完成 Resource 保存/加载与语义哈希。

const FORMAT_VERSION := 1

static func save_profile(profile: PCGSharedMaterialProfile, path: String) -> Error:
	return ResourceSaver.save(profile, path)

static func load_profile(path: String) -> PCGSharedMaterialProfile:
	var resource := ResourceLoader.load(path)
	if resource is PCGSharedMaterialProfile:
		return resource
	return null

static func hash_profile(profile: PCGSharedMaterialProfile) -> String:
	return hash_dict(profile.to_dict())

static func hash_dict(data: Dictionary) -> String:
	# 字段顺序固定（按键排序），浮点量化 1e-5，与路线图语义哈希口径一致。
	var keys := data.keys()
	keys.sort()
	var parts: Array[String] = []
	for key in keys:
		parts.append("%s=%s" % [key, _normalize(data[key])])
	return (String(";").join(PackedStringArray(parts))).sha256_text()

static func _normalize(value: Variant) -> String:
	if value is float:
		return "%.5f" % value
	if value is Array:
		var items: Array[String] = []
		for item in value:
			items.append(_normalize(item))
		return "[" + String(",").join(PackedStringArray(items)) + "]"
	return str(value)
