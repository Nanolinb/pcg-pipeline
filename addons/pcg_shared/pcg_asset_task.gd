@tool
class_name PCGAssetTask
extends Resource

# v0.15 L0 资产任务模型：一份“要什么资产”的可见、可校验、可溯源请求。
# 任务是纯数据（Resource 但不依赖任何节点/场景），由 PCGAssetTaskStore
# 以 JSON + format_version 信封原子持久化；AI 产物必须携带完整溯源字段。
# 校验分两档：draft（默认，只查枚举/取值合法性）与 assignment=true
# （任务可分配：完整 ID/名称/用途/尺寸范围/预算/接口 + AI 溯源）。

const FORMAT_VERSION := 1

const CATEGORIES: Array[StringName] = [
	&"door", &"window", &"support", &"sign", &"decoration", &"stairs", &"pipe", &"host", &"other",
]
const PRODUCERS: Array[StringName] = [&"human", &"ai", &"external", &"procedural"]
const PRECISION_TIERS: Array[StringName] = [&"near", &"mid", &"far"]
const STATUSES: Array[StringName] = [
	&"draft", &"assigned", &"candidate", &"pending_acceptance", &"accepted", &"rejected",
]
const ID_PATTERN := "^[a-z0-9_-]+$"

@export var format_version: int = FORMAT_VERSION
@export var task_id: StringName = &""
@export var display_name: String = ""
@export var category: StringName = &"other"
@export var purpose: String = ""
@export var style_tags: PackedStringArray = PackedStringArray()
@export var reference_urls: PackedStringArray = PackedStringArray()
@export var producer: StringName = &"human"
@export var source_tool: String = ""
@export var source_prompt: String = ""
@export var source_seed: String = ""
## 目标尺寸（米）；0 表示未指定，由 size_min/size_max 约束。
@export var target_size: Vector3 = Vector3.ZERO
@export var size_min: Vector3 = Vector3.ZERO
@export var size_max: Vector3 = Vector3.ZERO
@export var precision_tier: StringName = &"mid"
@export var tri_budget: int = 0
@export var lod1_budget: int = 0
@export var lod2_budget: int = 0
@export var texture_size: int = 0
@export var material_budget: int = 0
@export var origin_convention: String = "root_center"
@export var outward_axis: Vector3 = Vector3.BACK
@export var up_axis: Vector3 = Vector3.UP
@export var root_embed: float = 0.12
@export var interface_requirements: String = ""
@export var variable_appearance: String = ""
@export var fixed_features: String = ""
@export var prohibited_features: String = ""
@export var variant_count: int = 1
@export var status: StringName = &"draft"
@export var acceptance_notes: String = ""


func validation_errors(for_assignment: bool = false) -> Array[String]:
	var problems: Array[String] = []
	if format_version > FORMAT_VERSION:
		problems.append("task schema too new: format_version %d > %d" % [format_version, FORMAT_VERSION])
		return problems
	if not task_id.is_empty():
		var regex := RegEx.new()
		regex.compile(ID_PATTERN)
		if regex.search(String(task_id)) == null:
			problems.append("task_id \"%s\" must use lowercase ascii letters, digits, '_' or '-' only" % String(task_id))
	if not CATEGORIES.has(category):
		problems.append("category \"%s\" not in %s" % [String(category), ", ".join(CATEGORIES)])
	if not PRODUCERS.has(producer):
		problems.append("producer \"%s\" not in %s" % [String(producer), ", ".join(PRODUCERS)])
	if not PRECISION_TIERS.has(precision_tier):
		problems.append("precision_tier \"%s\" not in %s" % [String(precision_tier), ", ".join(PRECISION_TIERS)])
	if not STATUSES.has(status):
		problems.append("status \"%s\" not in %s" % [String(status), ", ".join(STATUSES)])
	if origin_convention.is_empty():
		problems.append("origin_convention is empty")
	if outward_axis.length_squared() < 0.000001:
		problems.append("outward_axis must be non-zero")
	elif not is_equal_approx(outward_axis.length_squared(), 1.0):
		problems.append("outward_axis must be normalized")
	if up_axis.length_squared() < 0.000001:
		problems.append("up_axis must be non-zero")
	elif not is_equal_approx(up_axis.length_squared(), 1.0):
		problems.append("up_axis must be normalized")
	if root_embed < 0.0:
		problems.append("root_embed must be >= 0")
	if variant_count < 1:
		problems.append("variant_count must be >= 1")
	if tri_budget < 0 or lod1_budget < 0 or lod2_budget < 0:
		problems.append("mesh budgets must be >= 0 (0 = unspecified)")
	if texture_size < 0:
		problems.append("texture_size must be >= 0 (0 = unspecified)")
	elif texture_size > 0 and (texture_size & (texture_size - 1)) != 0:
		problems.append("texture_size %d must be a power of two" % texture_size)
	if target_size.x < 0.0 or target_size.y < 0.0 or target_size.z < 0.0:
		problems.append("target_size components must be >= 0")
	if size_min.x < 0.0 or size_min.y < 0.0 or size_min.z < 0.0:
		problems.append("size_min components must be >= 0")
	if size_max.x < 0.0 or size_max.y < 0.0 or size_max.z < 0.0:
		problems.append("size_max components must be >= 0")
	if not for_assignment:
		return problems

	# --- 分配门槛：缺一项即不可分配，错误逐条列出 ---
	if task_id.is_empty():
		problems.append("assignment requires task_id")
	if display_name.is_empty():
		problems.append("assignment requires display_name")
	if purpose.is_empty():
		problems.append("assignment requires purpose")
	if interface_requirements.is_empty():
		problems.append("assignment requires interface_requirements")
	if _vec_any(size_min, 0.0) or _vec_any(size_max, 0.0):
		problems.append("assignment requires positive size_min/size_max on all axes")
	elif size_min.x > size_max.x or size_min.y > size_max.y or size_min.z > size_max.z:
		problems.append("assignment requires size_min <= size_max on every axis")
	if tri_budget <= 0 or lod1_budget <= 0 or lod2_budget <= 0:
		problems.append("assignment requires positive tri_budget/lod1_budget/lod2_budget")
	elif not (tri_budget >= lod1_budget and lod1_budget >= lod2_budget):
		problems.append("assignment requires LOD0 >= LOD1 >= LOD2 budgets (%d >= %d >= %d)"
			% [tri_budget, lod1_budget, lod2_budget])
	if texture_size <= 0:
		problems.append("assignment requires positive texture_size (power of two)")
	if material_budget <= 0:
		problems.append("assignment requires positive material_budget")
	if producer == &"ai":
		if source_tool.is_empty():
			problems.append("ai-produced task requires source_tool")
		if source_prompt.is_empty():
			problems.append("ai-produced task requires source_prompt")
		if source_seed.is_empty():
			problems.append("ai-produced task requires source_seed")
	return problems


func is_assignable() -> bool:
	return validation_errors(true).is_empty()


func to_dict() -> Dictionary:
	return {
		"format_version": format_version,
		"task_id": String(task_id),
		"display_name": display_name,
		"category": String(category),
		"purpose": purpose,
		"style_tags": Array(style_tags),
		"reference_urls": Array(reference_urls),
		"producer": String(producer),
		"source_tool": source_tool,
		"source_prompt": source_prompt,
		"source_seed": source_seed,
		"target_size": [target_size.x, target_size.y, target_size.z],
		"size_min": [size_min.x, size_min.y, size_min.z],
		"size_max": [size_max.x, size_max.y, size_max.z],
		"precision_tier": String(precision_tier),
		"tri_budget": tri_budget,
		"lod1_budget": lod1_budget,
		"lod2_budget": lod2_budget,
		"texture_size": texture_size,
		"material_budget": material_budget,
		"origin_convention": origin_convention,
		"outward_axis": [outward_axis.x, outward_axis.y, outward_axis.z],
		"up_axis": [up_axis.x, up_axis.y, up_axis.z],
		"root_embed": root_embed,
		"interface_requirements": interface_requirements,
		"variable_appearance": variable_appearance,
		"fixed_features": fixed_features,
		"prohibited_features": prohibited_features,
		"variant_count": variant_count,
		"status": String(status),
		"acceptance_notes": acceptance_notes,
	}


func from_dict(data: Dictionary) -> Array[String]:
	# 返回字段错误列表；非空即拒绝，调用方不得构建半份任务。
	var problems: Array[String] = []
	var raw_version := int(data.get("format_version", FORMAT_VERSION))
	if raw_version > FORMAT_VERSION:
		problems.append("task schema too new: format_version %d > %d" % [raw_version, FORMAT_VERSION])
	var raw_id := String(data.get("task_id", ""))
	if not raw_id.is_empty():
		var regex := RegEx.new()
		regex.compile(ID_PATTERN)
		if regex.search(raw_id) == null:
			problems.append("invalid field: task_id \"%s\"" % raw_id)
	var raw_category := StringName(String(data.get("category", "other")))
	if not raw_category.is_empty() and not CATEGORIES.has(raw_category):
		problems.append("invalid field: category \"%s\"" % String(raw_category))
	var raw_producer := StringName(String(data.get("producer", "human")))
	if not raw_producer.is_empty() and not PRODUCERS.has(raw_producer):
		problems.append("invalid field: producer \"%s\"" % String(raw_producer))
	var raw_tier := StringName(String(data.get("precision_tier", "mid")))
	if not raw_tier.is_empty() and not PRECISION_TIERS.has(raw_tier):
		problems.append("invalid field: precision_tier \"%s\"" % String(raw_tier))
	var raw_status := StringName(String(data.get("status", "draft")))
	if not raw_status.is_empty() and not STATUSES.has(raw_status):
		problems.append("invalid field: status \"%s\"" % String(raw_status))
	var axes: Dictionary = {}
	for axis_field in ["target_size", "size_min", "size_max", "outward_axis", "up_axis"]:
		var parsed: Variant = _parse_vec3(data.get(axis_field, null))
		if parsed == null:
			problems.append("invalid field: %s must be [x, y, z]" % axis_field)
		else:
			axes[axis_field] = parsed
	if problems.is_empty():
		format_version = raw_version
		task_id = StringName(raw_id)
		display_name = String(data.get("display_name", ""))
		category = raw_category
		purpose = String(data.get("purpose", ""))
		style_tags = PackedStringArray(data.get("style_tags", PackedStringArray()))
		reference_urls = PackedStringArray(data.get("reference_urls", PackedStringArray()))
		producer = raw_producer
		source_tool = String(data.get("source_tool", ""))
		source_prompt = String(data.get("source_prompt", ""))
		source_seed = String(data.get("source_seed", ""))
		target_size = axes["target_size"]
		size_min = axes["size_min"]
		size_max = axes["size_max"]
		precision_tier = raw_tier
		tri_budget = int(data.get("tri_budget", 0))
		lod1_budget = int(data.get("lod1_budget", 0))
		lod2_budget = int(data.get("lod2_budget", 0))
		texture_size = int(data.get("texture_size", 0))
		material_budget = int(data.get("material_budget", 0))
		origin_convention = String(data.get("origin_convention", "root_center"))
		outward_axis = axes["outward_axis"]
		up_axis = axes["up_axis"]
		root_embed = float(data.get("root_embed", 0.12))
		interface_requirements = String(data.get("interface_requirements", ""))
		variable_appearance = String(data.get("variable_appearance", ""))
		fixed_features = String(data.get("fixed_features", ""))
		prohibited_features = String(data.get("prohibited_features", ""))
		variant_count = maxi(1, int(data.get("variant_count", 1)))
		status = raw_status
		acceptance_notes = String(data.get("acceptance_notes", ""))
	return problems


static func _parse_vec3(raw: Variant) -> Variant:
	# 有效返回 Vector3，无效返回 null；宽松接受 Vector3 / [x,y,z] / {"x":..,"y":..,"z":..}。
	if raw is Vector3:
		return raw
	if raw is Array and (raw as Array).size() == 3:
		var items := raw as Array
		return Vector3(float(items[0]), float(items[1]), float(items[2]))
	if raw is Dictionary:
		var d := raw as Dictionary
		if d.has("x") and d.has("y") and d.has("z"):
			return Vector3(float(d["x"]), float(d["y"]), float(d["z"]))
	return null


static func _vec_any(v: Vector3, limit: float) -> bool:
	return v.x <= limit or v.y <= limit or v.z <= limit
