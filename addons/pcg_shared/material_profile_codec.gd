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
	# 全部委托 PCGCanonicalSerializer：字典键（含嵌套）按文本排序、
	# 浮点量化 1e-5，嵌套 Dictionary 不再依赖 str() 的不稳定顺序。
	return PCGCanonicalSerializer.hash_document(data)
