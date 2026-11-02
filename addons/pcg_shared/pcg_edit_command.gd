class_name PCGEditCommand
extends RefCounted

# v0.14 公共内核编辑命令（docs/core_contracts.md §2）。
# 纯数据/补丁模型：before/after 只携带受影响字段，
# 不以 NodePath 作为稳定身份（target_id 由消费者自行解析）。
# before/after 统一使用规范化序列化（字典键排序、浮点量化 1e-5，
# 见 PCGSharedMaterialCodec.hash_dict），命令流可哈希、可审计。

var command_id: StringName = &""
var target_id: StringName = &""
var scope: Dictionary = {}
var before: Dictionary = {}
var after: Dictionary = {}
var merge_key: StringName = &""
var timestamp_ms: int = 0

func to_dict() -> Dictionary:
	return {
		"command_id": String(command_id),
		"target_id": String(target_id),
		"scope": scope.duplicate(true),
		"before": before.duplicate(true),
		"after": after.duplicate(true),
		"merge_key": String(merge_key),
		"timestamp_ms": timestamp_ms,
	}

func from_dict(data: Dictionary) -> bool:
	if not data.has("command_id") or not data.has("target_id"):
		return false
	command_id = StringName(data["command_id"])
	target_id = StringName(data["target_id"])
	scope = (data.get("scope") if data.get("scope") is Dictionary else {}).duplicate(true)
	before = (data.get("before") if data.get("before") is Dictionary else {}).duplicate(true)
	after = (data.get("after") if data.get("after") is Dictionary else {}).duplicate(true)
	merge_key = StringName(data.get("merge_key", ""))
	timestamp_ms = int(data.get("timestamp_ms", 0))
	return true

# 补丁哈希：目标 + 作用域 + 双向补丁经规范化序列化后取 SHA-256。
# do→undo→redo 往返后同一命令的补丁哈希必须一致（验收 T10）。
func patch_hash() -> String:
	return PCGSharedMaterialCodec.hash_dict({
		"target_id": String(target_id),
		"scope": scope,
		"before": before,
		"after": after,
	})

# 把补丁中的向量/颜色等引擎类型展开为浮点数组，得到统一规范化序列化。
# 浮点的 1e-5 量化发生在哈希阶段（codec），此处保留原始 float。
func normalize_patch(patch: Dictionary) -> Dictionary:
	var result := {}
	for key in patch:
		result[String(key)] = normalize_value(patch[key])
	return result

static func normalize_value(value: Variant) -> Variant:
	if value is Vector2:
		return [value.x, value.y]
	if value is Vector3:
		return [value.x, value.y, value.z]
	if value is Color:
		return [value.r, value.g, value.b, value.a]
	if value is Array:
		var items: Array = []
		for item in value:
			items.append(normalize_value(item))
		return items
	if value is Dictionary:
		var result := {}
		var keys: Array = value.keys()
		keys.sort()
		for key in keys:
			result[String(key)] = normalize_value(value[key])
		return result
	return value
