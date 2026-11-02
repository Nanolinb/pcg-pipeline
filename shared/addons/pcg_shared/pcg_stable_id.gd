@tool
class_name PCGStableId
extends Resource

# v0.14 公共内核：稳定 ID（docs/core_contracts.md §1.1）。
# 发布后不变；不依赖 NodePath、节点名或文件显示名。
# created_with 仅审计、display_name 可修改，两者均不参与签名。

const ID_VERSION := 1
const ID_PATTERN := "^[a-z0-9_-]+$"

@export var id: StringName = &""
@export var id_version: int = ID_VERSION
@export var created_with: String = ""
@export var display_name: String = ""

static var _generate_counter: int = 0


static func generate(prefix: StringName = &"id") -> PCGStableId:
	# ID 生成不触碰全局随机状态；使用本地 RNG + 时间 + 计数器。
	_generate_counter += 1
	var rid := RandomNumberGenerator.new()
	rid.seed = hash("%d:%d" % [Time.get_ticks_usec(), _generate_counter]) & 0x7fffffffffffffff
	var stable := PCGStableId.new()
	stable.id = StringName("%s_%08x%04x" % [String(prefix), rid.randi(), rid.randi() & 0xffff])
	stable.id_version = ID_VERSION
	return stable


func validate() -> Array[String]:
	var problems: Array[String] = []
	if String(id).is_empty():
		problems.append("id is empty")
	else:
		var regex := RegEx.new()
		regex.compile(ID_PATTERN)
		if regex.search(String(id)) == null:
			problems.append("id \"%s\" must use lowercase ascii letters, digits, '_' or '-' only" % String(id))
	if id_version != ID_VERSION:
		problems.append("unsupported id_version %d (current %d)" % [id_version, ID_VERSION])
	return problems


func is_valid_id() -> bool:
	return validate().is_empty()


func signature_fields() -> Dictionary:
	# 参与重建签名的最小身份字段；审计与显示字段明确排除。
	return {
		"id": String(id),
		"id_version": id_version,
	}


func to_dict() -> Dictionary:
	return {
		"id": String(id),
		"id_version": id_version,
		"created_with": created_with,
		"display_name": display_name,
	}


func from_dict(data: Dictionary) -> Array[String]:
	# 返回字段错误列表；非空即拒绝，调用方不得构建半份对象。
	var problems: Array[String] = []
	var raw_id := String(data.get("id", ""))
	if raw_id.is_empty():
		problems.append("missing field: id")
	else:
		var regex := RegEx.new()
		regex.compile(ID_PATTERN)
		if regex.search(raw_id) == null:
			problems.append("invalid field: id \"%s\"" % raw_id)
	var raw_version := int(data.get("id_version", ID_VERSION))
	if raw_version > ID_VERSION:
		problems.append("id schema too new: %d > %d" % [raw_version, ID_VERSION])
	if problems.is_empty():
		id = StringName(raw_id)
		id_version = raw_version
		created_with = String(data.get("created_with", ""))
		display_name = String(data.get("display_name", ""))
	return problems
