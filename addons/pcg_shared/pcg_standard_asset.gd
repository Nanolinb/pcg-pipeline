@tool
class_name PCGStandardAsset
extends Resource

# v0.16 L1 标准资产：一份“交付了什么资产”的可见、可校验、可溯源发布物。
# 任务是请求（PCGAssetTask），标准资产是验收后的交付：稳定 ID、任务引用、
# 规范化网格（LOD0）、真实 LOD1/2、白盒、尺寸/根部约定、UV/碰撞策略、
# 材质 Profile 引用、验收报告与五类占用区域（occupancy）。
# 由 PCGStandardAssetStore 原子发布到 assets/published（JSON 信封 + 每级网格
# .res）；网格本体不内嵌 JSON。
#
# occupancy 语义（资产局部坐标 AABB，min/max 显式序列化）：
# - solid：资产实体占用（网格 AABB）。
# - embed：根部嵌入宿主的部分（根部平面 inward 侧厚 root_embed 的板区与实体的交）。
# - exclusion：宿主上不得再装其他组件的区域（embed 外扩 OCCUPANCY_MARGIN）。
# - clearance：资产周围必须留空的区域（solid 外扩净空余量，默认 OCCUPANCY_MARGIN）。
# - visual：视觉呈现范围（solid 外扩视觉余量，默认 VISUAL_MARGIN）。
# 发布时若为空则由网格与 root_embed 推导（余量可由调用方指定，窗口传入
# 用户编辑值）；加载时逐区校验，缺失/非法一律拒绝。
#
# LOD 纪律：lod1_mesh/lod2_mesh 允许显式提供（lod_status="explicit"）；
# 否则由 PCGMeshLod 真实减面（lod_status="auto"）。任何情况下都不得
# 把 LOD0 静默复制充当高级 LOD —— 低于预算时也会显式标注
# passthrough_below_budget。

const FORMAT_VERSION := 1

const LOD_STATUSES: Array[StringName] = [&"auto", &"explicit"]
const ACCEPTANCE_VERDICTS: Array[StringName] = [&"accepted", &"accepted_with_notes", &"rejected"]
const REPORT_FIELDS: Array[String] = ["verdict", "checked_by", "checked_at", "notes"]
## 五类占用区域的固定槽位；序列化为 {slot: {"min": [x,y,z], "max": [x,y,z]}}。
const OCCUPANCY_SLOTS: Array[String] = ["solid", "embed", "exclusion", "clearance", "visual"]
const OCCUPANCY_MARGIN := 0.05
const VISUAL_MARGIN := 0.01

@export var format_version: int = FORMAT_VERSION
## 身份：发布后不变（规则同 docs/core_contracts.md §1.1）。
@export var stable_id: PCGStableId
@export var display_name: String = ""
@export var category: StringName = &"other"
## 产生本资产的任务引用（PCGAssetTask.task_id）。
@export var task_id: StringName = &""
## 来源路径/URL（原始产物、外部仓库或中间稿）。
@export var source_path: String = ""
## 规范化网格：唯一 LOD0 真源，发布必填。
@export var normalized_mesh: ArrayMesh
## 目标尺寸（米）；Vector3.ZERO 表示由 normalized_mesh 的 AABB 派生。
@export var dimensions: Vector3 = Vector3.ZERO
## 根点相对网格原点的偏移；试装时根点对齐宿主表面锚点。
@export var root_offset: Vector3 = Vector3.ZERO
## 根部沿表面内法向嵌入宿主的深度（米）。
@export var root_embed: float = 0.12
## 资产局部朝外/朝上轴，用于试装时与宿主表面对齐。
@export var outward_axis: Vector3 = Vector3.BACK
@export var up_axis: Vector3 = Vector3.UP
@export var uv_policy: StringName = &"world_scale"
@export var collision_policy: StringName = &"box"
## 材质 Profile 引用：内存中持资源，持久化存路径（material_profile_path）。
@export var material_profile: PCGMaterialProfile
@export var material_profile_path: String = ""
@export var producer: StringName = &"human"
@export var source_tool: String = ""
@export var source_prompt: String = ""
@export var source_seed: String = ""
## 验收报告：必填。至少含 verdict/checked_by/checked_at/notes。
@export var acceptance_report: Dictionary = {}
## 显式 LOD（可选）；为空时由 Store 自动真实减面。
@export var lod1_mesh: ArrayMesh
@export var lod2_mesh: ArrayMesh
## 每级 LOD 的来源状态（lod1、lod2 各一项）：auto / explicit。
@export var lod_status: PackedStringArray = PackedStringArray(["auto", "auto"])
## LOD 目标面数；0 = 由 Store 按 LOD0 面数推导（1/4、1/16）。
@export var lod1_target_faces: int = 0
@export var lod2_target_faces: int = 0
## 发布时生成的白盒（AABB 盒网格），随资产持久化。
@export var whitebox_mesh: ArrayMesh
## 五类占用区域（solid/embed/exclusion/clearance/visual），AABB 字典；
## 发布时为空则由网格与 root_embed 推导，加载时逐区校验。
@export var occupancy: Dictionary = {}
## 持久化的网格文件名（Store 发布/重载时维护）：lod0/lod1/lod2/whitebox。
@export var mesh_files: Dictionary = {}


func asset_id() -> StringName:
	return stable_id.id if stable_id != null else &""


## 有效尺寸：显式 dimensions 优先，否则取规范化网格 AABB。
func resolved_dimensions() -> Vector3:
	if dimensions != Vector3.ZERO:
		return dimensions
	if normalized_mesh != null:
		return normalized_mesh.get_aabb().size
	return Vector3.ZERO


## 规范化网格 AABB（资产局部坐标）；无网格返回空 AABB。
func mesh_aabb() -> AABB:
	if normalized_mesh == null:
		return AABB()
	return normalized_mesh.get_aabb()


## 取某一占用区域的 AABB；槽位缺失/非法返回空 AABB。
func occupancy_zone(slot: String) -> AABB:
	var parsed: Variant = parse_aabb(occupancy.get(slot, null))
	return parsed if parsed is AABB else AABB()


## 由规范化网格 AABB 与 root_embed 推导五类占用区域（资产局部坐标）。
## clearance_margin/visual_margin 指定 clearance/visual 的外扩余量（负值按 0
## 处理）；缺省用 OCCUPANCY_MARGIN / VISUAL_MARGIN。无网格时返回空字典
## （调用方应以校验错误处理）。
func derive_occupancy(clearance_margin: float = OCCUPANCY_MARGIN,
		visual_margin: float = VISUAL_MARGIN) -> Dictionary:
	var solid := mesh_aabb()
	if normalized_mesh == null or solid.size == Vector3.ZERO:
		return {}
	var embed := _derive_embed_zone(solid)
	return {
		"solid": serialize_aabb(solid),
		"embed": serialize_aabb(embed),
		"exclusion": serialize_aabb(embed.grow(OCCUPANCY_MARGIN)),
		"clearance": serialize_aabb(solid.grow(maxf(clearance_margin, 0.0))),
		"visual": serialize_aabb(solid.grow(maxf(visual_margin, 0.0))),
	}


## 嵌入区：根部平面（过 root_offset、法向 outward_axis）inward 侧
## 厚 root_embed 的板层与实体 AABB 的交；不相交、depth<=0 或 outward_axis
## 为零时返回 root_offset 处的零尺寸 AABB（合法占位，不做负尺寸）。
## 板层：-root_embed <= (p - root_offset)·outward_axis <= 0。凸体交集的
## AABB 逐轴精确求解：沿轴 a 的边界由其余轴范围上法向投影的极值决定，
## 旋转轴（非轴对齐 outward_axis）不再按主轴近似裁剪。
func _derive_embed_zone(aabb: AABB) -> AABB:
	if root_embed <= 0.0:
		return AABB(root_offset, Vector3.ZERO)
	var normal := outward_axis.normalized()
	if normal.length_squared() < 0.000001:
		return AABB(root_offset, Vector3.ZERO)
	var lo := aabb.position
	var hi := aabb.end
	for axis in 3:
		var na: float = normal[axis]
		if is_zero_approx(na):
			continue
		# S = Σ_{i≠a} n_i·(p_i - root_offset_i) 在实体其余轴范围上的极值。
		var s_min := 0.0
		var s_max := 0.0
		for other in 3:
			if other == axis:
				continue
			var contribution_lo: float = normal[other] * (lo[other] - root_offset[other])
			var contribution_hi: float = normal[other] * (hi[other] - root_offset[other])
			s_min += minf(contribution_lo, contribution_hi)
			s_max += maxf(contribution_lo, contribution_hi)
		# na·(p_a - root_offset_a) ∈ [-root_embed - S, -S]；最紧边界取 S 的对应极值。
		var bound_lo := (-root_embed - s_max) / na
		var bound_hi := (-s_min) / na
		if na < 0.0:
			var swap := bound_lo
			bound_lo = bound_hi
			bound_hi = swap
		lo[axis] = maxf(lo[axis], root_offset[axis] + bound_lo)
		hi[axis] = minf(hi[axis], root_offset[axis] + bound_hi)
	if lo.x > hi.x or lo.y > hi.y or lo.z > hi.z:
		return AABB(root_offset, Vector3.ZERO)
	return AABB(lo, hi - lo)


static func serialize_aabb(box: AABB) -> Dictionary:
	return {
		"min": [box.position.x, box.position.y, box.position.z],
		"max": [box.end.x, box.end.y, box.end.z],
	}


## 解析 {"min": [x,y,z], "max": [x,y,z]}；合法返回 AABB（允许零尺寸），
## 非法或 min > max 返回 null。
static func parse_aabb(raw: Variant) -> Variant:
	if not (raw is Dictionary):
		return null
	var data := raw as Dictionary
	if not data.has("min") or not data.has("max"):
		return null
	var lo: Variant = PCGAssetTask._parse_vec3(data["min"])
	var hi: Variant = PCGAssetTask._parse_vec3(data["max"])
	if lo == null or hi == null:
		return null
	var size: Vector3 = (hi as Vector3) - (lo as Vector3)
	if size.x < 0.0 or size.y < 0.0 or size.z < 0.0:
		return null
	return AABB(lo, size)


func validation_errors() -> Array[String]:
	# 发布级校验：缺一项即拒绝发布，错误逐条列出。
	var problems: Array[String] = []
	if format_version > FORMAT_VERSION:
		problems.append("asset schema too new: format_version %d > %d"
			% [format_version, FORMAT_VERSION])
		return problems
	if stable_id == null:
		problems.append("stable_id is missing")
	else:
		for line in stable_id.validate():
			problems.append("stable_id: " + line)
	if display_name.is_empty():
		problems.append("display_name is empty")
	if not PCGAssetTask.CATEGORIES.has(StringName(String(category))):
		problems.append("category \"%s\" not in %s" % [String(category), ", ".join(PCGAssetTask.CATEGORIES)])
	if String(task_id).is_empty():
		problems.append("task reference (task_id) is empty")
	else:
		var regex := RegEx.new()
		regex.compile(PCGAssetTask.ID_PATTERN)
		if regex.search(String(task_id)) == null:
			problems.append("task_id \"%s\" must use lowercase ascii letters, digits, '_' or '-' only" % String(task_id))
	if source_path.is_empty():
		problems.append("source_path is empty")
	if normalized_mesh == null or normalized_mesh.get_surface_count() == 0:
		problems.append("normalized_mesh (LOD0) is missing or empty")
	if not PCGAssetTask.UV_POLICIES.has(StringName(String(uv_policy))):
		problems.append("uv_policy \"%s\" not in %s" % [String(uv_policy), ", ".join(PCGAssetTask.UV_POLICIES)])
	if not PCGAssetTask.COLLISION_POLICIES.has(StringName(String(collision_policy))):
		problems.append("collision_policy \"%s\" not in %s" % [String(collision_policy), ", ".join(PCGAssetTask.COLLISION_POLICIES)])
	if not PCGAssetTask.PRODUCERS.has(StringName(String(producer))):
		problems.append("producer \"%s\" not in %s" % [String(producer), ", ".join(PCGAssetTask.PRODUCERS)])
	if producer == &"ai":
		if source_tool.is_empty():
			problems.append("ai-produced asset requires source_tool")
		if source_prompt.is_empty():
			problems.append("ai-produced asset requires source_prompt")
		if source_seed.is_empty():
			problems.append("ai-produced asset requires source_seed")
	if root_embed < 0.0:
		problems.append("root_embed must be >= 0")
	if outward_axis.length_squared() < 0.000001:
		problems.append("outward_axis must be non-zero")
	elif not is_equal_approx(outward_axis.length_squared(), 1.0):
		problems.append("outward_axis must be normalized")
	if up_axis.length_squared() < 0.000001:
		problems.append("up_axis must be non-zero")
	elif not is_equal_approx(up_axis.length_squared(), 1.0):
		problems.append("up_axis must be normalized")
	if dimensions.x < 0.0 or dimensions.y < 0.0 or dimensions.z < 0.0:
		problems.append("dimensions components must be >= 0")
	if lod1_target_faces < 0 or lod2_target_faces < 0:
		problems.append("lod target faces must be >= 0 (0 = derived)")
	_append_report_errors(problems)
	_append_occupancy_errors(problems)
	if material_profile != null and material_profile_path.is_empty():
		problems.append("material_profile is set but material_profile_path is empty; \
save the profile to a resource path before publishing")
	if not material_profile_path.is_empty() and not FileAccess.file_exists(material_profile_path):
		problems.append("material_profile_path does not exist: %s" % material_profile_path)
	return problems


static func _enum_or_empty(data: Dictionary, field: String, fallback: String) -> StringName:
	# 显式 null（热重载中间态）按非法空值处理，绝不当默认值放过。
	var raw: Variant = data.get(field, fallback)
	return StringName(String(raw)) if raw != null else StringName("")


func _append_occupancy_errors(problems: Array[String]) -> void:
	if occupancy.is_empty():
		problems.append("occupancy is missing; publish derives it from mesh/root_embed")
		return
	for key in occupancy:
		if not OCCUPANCY_SLOTS.has(String(key)):
			problems.append("occupancy has unknown zone \"%s\" (allowed: %s)"
				% [String(key), ", ".join(OCCUPANCY_SLOTS)])
	for slot in OCCUPANCY_SLOTS:
		if not occupancy.has(slot):
			problems.append("occupancy missing zone \"%s\"" % slot)
			continue
		var parsed: Variant = parse_aabb(occupancy[slot])
		if parsed == null:
			problems.append("occupancy zone \"%s\" must be {\"min\": [x,y,z], \"max\": [x,y,z]} with min <= max"
				% slot)


func _append_report_errors(problems: Array[String]) -> void:
	if acceptance_report.is_empty():
		problems.append("acceptance_report is missing; assets must be accepted before publish")
		return
	for field in REPORT_FIELDS:
		if not acceptance_report.has(field):
			problems.append("acceptance_report missing field \"%s\"" % field)
			return
	var verdict := StringName(String(acceptance_report.get("verdict", "")))
	if not ACCEPTANCE_VERDICTS.has(verdict):
		problems.append("acceptance_report verdict \"%s\" not in %s"
			% [String(verdict), ", ".join(ACCEPTANCE_VERDICTS)])
		return
	if verdict == &"rejected":
		problems.append("acceptance_report verdict is \"rejected\"; fix and re-accept before publish")
		return
	if String(acceptance_report.get("checked_by", "")).is_empty():
		problems.append("acceptance_report checked_by is empty")


func to_dict() -> Dictionary:
	return {
		"format_version": FORMAT_VERSION,
		"stable_id": stable_id.to_dict() if stable_id != null else {},
		"display_name": display_name,
		"category": String(category),
		"task_id": String(task_id),
		"source_path": source_path,
		"dimensions": [dimensions.x, dimensions.y, dimensions.z],
		"root_offset": [root_offset.x, root_offset.y, root_offset.z],
		"root_embed": root_embed,
		"outward_axis": [outward_axis.x, outward_axis.y, outward_axis.z],
		"up_axis": [up_axis.x, up_axis.y, up_axis.z],
		"uv_policy": String(uv_policy),
		"collision_policy": String(collision_policy),
		"material_profile_path": material_profile_path,
		"producer": String(producer),
		"source_tool": source_tool,
		"source_prompt": source_prompt,
		"source_seed": source_seed,
		"acceptance_report": acceptance_report.duplicate(),
		"lod_status": Array(lod_status),
		"lod1_target_faces": lod1_target_faces,
		"lod2_target_faces": lod2_target_faces,
		"occupancy": occupancy.duplicate(),
		"mesh_files": mesh_files.duplicate(),
	}


func from_dict(data: Dictionary) -> Array[String]:
	# 返回字段错误列表；非空即拒绝，调用方不得构建半份资产。
	var problems: Array[String] = []
	var raw_version := int(data.get("format_version", FORMAT_VERSION))
	if raw_version > FORMAT_VERSION:
		problems.append("asset schema too new: format_version %d > %d" % [raw_version, FORMAT_VERSION])
	var raw_category := _enum_or_empty(data, "category", "other")
	if not PCGAssetTask.CATEGORIES.has(raw_category):
		problems.append("invalid field: category \"%s\"" % String(raw_category))
	var raw_uv := _enum_or_empty(data, "uv_policy", "world_scale")
	if not PCGAssetTask.UV_POLICIES.has(raw_uv):
		problems.append("invalid field: uv_policy \"%s\"" % String(raw_uv))
	var raw_collision := _enum_or_empty(data, "collision_policy", "box")
	if not PCGAssetTask.COLLISION_POLICIES.has(raw_collision):
		problems.append("invalid field: collision_policy \"%s\"" % String(raw_collision))
	var raw_producer := _enum_or_empty(data, "producer", "human")
	if not PCGAssetTask.PRODUCERS.has(raw_producer):
		problems.append("invalid field: producer \"%s\"" % String(raw_producer))
	var raw_lod_status := PackedStringArray(data.get("lod_status", PackedStringArray()))
	for status in raw_lod_status:
		if not LOD_STATUSES.has(StringName(String(status))):
			problems.append("invalid field: lod_status \"%s\"" % String(status))
	var axes: Dictionary = {}
	for axis_field in ["dimensions", "root_offset", "outward_axis", "up_axis"]:
		var parsed: Variant = PCGAssetTask._parse_vec3(data.get(axis_field, null))
		if parsed == null:
			problems.append("invalid field: %s must be [x, y, z]" % axis_field)
		else:
			axes[axis_field] = parsed
	var report_raw: Variant = data.get("acceptance_report", null)
	if report_raw == null:
		problems.append("missing field: acceptance_report")
	elif not (report_raw is Dictionary):
		problems.append("invalid field: acceptance_report must be an object")
	var mesh_files_raw: Variant = data.get("mesh_files", null)
	if mesh_files_raw == null:
		problems.append("missing field: mesh_files")
	elif not (mesh_files_raw is Dictionary):
		problems.append("invalid field: mesh_files must be an object")
	else:
		for slot in ["lod0", "lod1", "lod2", "whitebox"]:
			if String((mesh_files_raw as Dictionary).get(slot, "")).is_empty():
				problems.append("mesh_files missing entry \"%s\"" % slot)
	var occupancy_raw: Variant = data.get("occupancy", null)
	var occupancy_parsed := {}
	if occupancy_raw == null:
		problems.append("missing field: occupancy")
	elif not (occupancy_raw is Dictionary):
		problems.append("invalid field: occupancy must be an object")
	else:
		var occ := occupancy_raw as Dictionary
		for key in occ:
			if not OCCUPANCY_SLOTS.has(String(key)):
				problems.append("invalid field: occupancy unknown zone \"%s\"" % String(key))
		for slot in OCCUPANCY_SLOTS:
			if not occ.has(slot):
				problems.append("invalid field: occupancy missing zone \"%s\"" % slot)
				continue
			var zone: Variant = parse_aabb(occ[slot])
			if zone == null:
				problems.append("invalid field: occupancy zone \"%s\" must be min/max with min <= max" % slot)
			else:
				occupancy_parsed[slot] = serialize_aabb(zone)
	var id_raw: Variant = data.get("stable_id", null)
	if id_raw == null or not (id_raw is Dictionary):
		problems.append("missing field: stable_id")
	if problems.is_empty():
		var sid := PCGStableId.new()
		var sid_problems := sid.from_dict(id_raw as Dictionary)
		if not sid_problems.is_empty():
			for line in sid_problems:
				problems.append("invalid field: stable_id " + line)
	if problems.is_empty():
		stable_id = PCGStableId.new()
		stable_id.from_dict(id_raw as Dictionary)
		display_name = String(data.get("display_name", ""))
		category = raw_category
		task_id = StringName(String(data.get("task_id", "")))
		source_path = String(data.get("source_path", ""))
		dimensions = axes["dimensions"]
		root_offset = axes["root_offset"]
		root_embed = float(data.get("root_embed", 0.12))
		outward_axis = axes["outward_axis"]
		up_axis = axes["up_axis"]
		uv_policy = raw_uv
		collision_policy = raw_collision
		material_profile_path = String(data.get("material_profile_path", ""))
		producer = raw_producer
		source_tool = String(data.get("source_tool", ""))
		source_prompt = String(data.get("source_prompt", ""))
		source_seed = String(data.get("source_seed", ""))
		acceptance_report = (report_raw as Dictionary).duplicate()
		lod_status = raw_lod_status
		lod1_target_faces = int(data.get("lod1_target_faces", 0))
		lod2_target_faces = int(data.get("lod2_target_faces", 0))
		occupancy = occupancy_parsed
		mesh_files = (mesh_files_raw as Dictionary).duplicate()
	return problems
