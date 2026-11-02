class_name PCGCanonicalSerializer
extends RefCounted

# v0.14 公共内核：规范化序列化与语义哈希（docs/core_contracts.md §5.1）。
#
# - 字典键按文本排序；数组保持顺序并记录长度。
# - 浮点统一量化到 1e-5，输出定点文本（固定 5 位小数）。
#   Godot 的 "%" 格式化与区域设置无关（始终 "." 小数点），不依赖 %g。
# - 语义哈希 = 规范化文本的 SHA-256。派生值不替代原始输入：
#   调用方必须保留 user_scale / neighborhood_scale 等各原始字段，
#   本类只负责忠实编码收到的字典。

const FLOAT_DECIMALS := 5
const QUANTUM := 1e-5


static func encode_float(value: float) -> String:
	# 定点文本：1.0 -> "1.00000"；量化步长 1e-5。
	# -0.0 与 0.0 在 1e-5 精度下等价，统一为 "0.00000"。
	if value == 0.0:
		value = 0.0
	return "%.5f" % value


static func encode(value: Variant) -> String:
	match typeof(value):
		TYPE_NIL:
			return "null"
		TYPE_BOOL:
			return "true" if value else "false"
		TYPE_INT:
			return str(value)
		TYPE_FLOAT:
			return encode_float(value)
		TYPE_STRING, TYPE_STRING_NAME:
			return String(value)
		TYPE_ARRAY:
			var items: Array[String] = []
			for item in value:
				items.append(encode(item))
			# 记录长度，避免截断歧义。
			return "[%d](%s)" % [value.size(), String(",").join(PackedStringArray(items))]
		TYPE_DICTIONARY:
			var keys := (value as Dictionary).keys()
			keys.sort_custom(func(a: Variant, b: Variant) -> bool: return String(a) < String(b))
			var parts: Array[String] = []
			for key in keys:
				parts.append("%s:%s" % [encode(key), encode((value as Dictionary)[key])])
			return "{%s}" % String(";").join(PackedStringArray(parts))
	push_error("PCGCanonicalSerializer: unsupported type %s" % type_string(typeof(value)))
	return ""


static func canonical_text(data: Dictionary) -> String:
	return encode(data)


static func hash_document(data: Dictionary) -> String:
	return canonical_text(data).sha256_text()


static func hash_text(text: String) -> String:
	return text.sha256_text()
