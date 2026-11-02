@tool
class_name PCGSharedMaterialProfile
extends Resource

# BASE-05 共享载体 Spike：Material Profile 小模块。
# 单源位于 shared/addons/pcg_shared/，由根工程、PipeWeaver 与最小第三方消费者
# 通过 addons 链接加载。字段子集与两主程序现有 PCGMaterialProfile 语义兼容，
# 但 class_name 独立，避免与尚未迁移的本地副本冲突。

const FORMAT_VERSION := 1
const SLOT_IDS: Array[StringName] = [&"base_color", &"detail", &"normal", &"orm"]

@export var display_name: StringName = &""
@export var tint: Color = Color.WHITE
@export var roughness: float = 0.5
@export var metallic: float = 0.0
@export_range(1.0, 16.0, 0.5) var detail_tiling: float = 6.0

func validate() -> Array[String]:
	var problems: Array[String] = []
	if display_name == &"":
		problems.append("display_name is empty")
	if not (roughness >= 0.0 and roughness <= 1.0):
		problems.append("roughness out of range [0,1]")
	if not (metallic >= 0.0 and metallic <= 1.0):
		problems.append("metallic out of range [0,1]")
	if detail_tiling <= 0.0:
		problems.append("detail_tiling must be positive")
	return problems

func to_dict() -> Dictionary:
	return {
		"format_version": FORMAT_VERSION,
		"display_name": String(display_name),
		"tint": [tint.r, tint.g, tint.b, tint.a],
		"roughness": roughness,
		"metallic": metallic,
		"detail_tiling": detail_tiling,
	}

func from_dict(data: Dictionary) -> bool:
	if not data.has("format_version"):
		return false
	if int(data["format_version"]) > FORMAT_VERSION:
		return false
	display_name = StringName(data.get("display_name", ""))
	var tint_array: Array = data.get("tint", [1.0, 1.0, 1.0, 1.0])
	tint = Color(float(tint_array[0]), float(tint_array[1]), float(tint_array[2]), float(tint_array[3]))
	roughness = float(data.get("roughness", 0.5))
	metallic = float(data.get("metallic", 0.0))
	detail_tiling = float(data.get("detail_tiling", 6.0))
	return true

func is_same_profile(other: PCGSharedMaterialProfile) -> bool:
	if other == null:
		return false
	return to_dict() == other.to_dict()

func build_material() -> StandardMaterial3D:
	var material := StandardMaterial3D.new()
	material.resource_name = String(display_name)
	material.albedo_color = tint
	material.roughness = roughness
	material.metallic = metallic
	material.uv1_scale = Vector3(detail_tiling, detail_tiling, detail_tiling)
	return material
