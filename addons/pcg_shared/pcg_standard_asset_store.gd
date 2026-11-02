@tool
class_name PCGStandardAssetStore
extends RefCounted

# v0.16 L1 标准资产发布：PCGAtomicStore + JSON 信封 + 每级网格 .res。
# 默认目录 res://assets/published，可被调用方覆盖（例如 user:// 测试目录）。
#
# 发布纪律：
# - 校验不过（缺 Mesh / 缺验收报告 / 非法字段）绝不触碰磁盘。
# - 目录内已存在同 ID 资产 → 拒绝重复发布（发布是不可变操作，不覆盖）。
# - LOD1/2 优先用资产自带的显式网格（lod_status="explicit"），否则
#   PCGMeshLod 真实减面（lod_status="auto"）；能力检查失败时拒绝并提示
#   提供显式 LOD，绝不静默复制 LOD0。
# - 网格 .res 先写临时文件再 rename 提交；JSON 走 PCGAtomicStore。
#   任一步失败清理本次已写文件，不留半成品。
# 重载纪律：缺任何网格文件 / 缺验收报告 / 字段非法 → 拒绝，绝不返回半份资产。

const DEFAULT_DIRECTORY := "res://assets/published"
const FILE_SUFFIX := ".asset.json"
const MESH_SUFFIX := ".mesh.res"
const TEMP_SUFFIX := ".tmp"
const APP_VERSION := "0.16.0"

const MESH_SLOTS: Array[String] = ["lod0", "lod1", "lod2", "whitebox"]
const LOD_LEVELS: Array[int] = [1, 2]

var directory: String = DEFAULT_DIRECTORY
var atomic_store: PCGAtomicStore = PCGAtomicStore.new()
## 最近一次 list_assets 的逐文件报告（含坏文件与重复 ID 说明）。
var last_report: Array[String] = []
## 最近一次 publish 的 LOD 生成明细（调试/审计用）。
var last_publish_manifest: Dictionary = {}


func _init() -> void:
	atomic_store.content_validator = func(content: String) -> Array[String]:
		var problems: Array[String] = []
		var json := JSON.new()
		if json.parse(content) != OK or not (json.data is Dictionary):
			problems.append("document is not a valid JSON object")
		elif not (json.data as Dictionary).has("format_version"):
			problems.append("document has no format_version")
		return problems


func asset_path(asset_id: StringName, asset_directory: String = "") -> String:
	return _resolve_dir(asset_directory) + "/" + String(asset_id) + FILE_SUFFIX


## 发布一份标准资产。返回 {ok, path, errors, manifest}。
## fault 透传给 PCGAtomicStore 模拟 JSON 写入中断（测试用）。
func publish(asset: PCGStandardAsset, asset_directory: String = "", fault: String = "") -> Dictionary:
	var errors: Array[String] = asset.validation_errors()
	if not errors.is_empty():
		return {"ok": false, "path": "", "errors": errors, "manifest": {}}
	var dir := _resolve_dir(asset_directory)
	if DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(dir)) != OK:
		return {"ok": false, "path": "", "errors": ["cannot create directory %s" % dir], "manifest": {}}
	var id := String(asset.asset_id())
	var path := asset_path(asset.asset_id(), dir)
	if FileAccess.file_exists(path):
		return {"ok": false, "path": path,
			"errors": ["duplicate asset id \"%s\": already published at %s" % [id, path]], "manifest": {}}

	# LOD 解析：显式优先，否则真实减面；白盒由 AABB 生成。
	var meshes := {"lod0": asset.normalized_mesh}
	var lod_statuses: Array[String] = []
	var manifest := {"asset_id": id, "lods": {}, "faces": {}}
	var lod0_faces: int = int(PCGMeshLod.capability(asset.normalized_mesh)["faces"])
	manifest["faces"]["lod0"] = lod0_faces
	for level in LOD_LEVELS:
		var explicit: ArrayMesh = asset.get("lod%d_mesh" % level)
		if explicit != null and explicit.get_surface_count() > 0:
			meshes["lod%d" % level] = explicit
			lod_statuses.append("explicit")
			manifest["lods"]["lod%d" % level] = {
				"method": "explicit", "faces": _face_count(explicit)}
			manifest["faces"]["lod%d" % level] = _face_count(explicit)
			continue
		var target := int(asset.get("lod%d_target_faces" % level))
		if target <= 0:
			target = maxi(1, lod0_faces >> (level * 2))
		var decimated: Dictionary = PCGMeshLod.decimate(asset.normalized_mesh, target)
		if not decimated["ok"]:
			return {"ok": false, "path": "", "errors": [String(decimated["errors"][0])], "manifest": {}}
		meshes["lod%d" % level] = decimated["mesh"]
		lod_statuses.append("auto")
		manifest["lods"]["lod%d" % level] = {
			"method": decimated["method"], "faces_in": decimated["faces_in"],
			"faces_out": decimated["faces_out"], "cell_size": decimated["cell_size"],
			"target_faces": target,
			"warning": String(decimated.get("warning", ""))}
		manifest["faces"]["lod%d" % level] = decimated["faces_out"]
	var whitebox := asset.whitebox_mesh
	if whitebox == null:
		whitebox = PCGSurfacePreview.make_whitebox_mesh(asset.mesh_aabb())
	asset.whitebox_mesh = whitebox
	meshes["whitebox"] = whitebox
	manifest["faces"]["whitebox"] = _face_count(whitebox)

	# 网格落盘：临时文件 + rename；失败清理本次已写文件。
	var written: Array[String] = []
	for slot in MESH_SLOTS:
		var mesh_path := _mesh_path(dir, id, slot)
		var saved := _save_mesh_atomic(meshes[slot], mesh_path)
		if saved != OK:
			for cleanup in written:
				DirAccess.remove_absolute(ProjectSettings.globalize_path(cleanup))
			return {"ok": false, "path": "",
				"errors": ["cannot save %s mesh to %s (err=%d)" % [slot, mesh_path, saved]],
				"manifest": {}}
		written.append(mesh_path)

	# JSON 信封（含发布时确定的 LOD 状态与网格文件名）。
	asset.lod_status = PackedStringArray(lod_statuses)
	asset.mesh_files = {}
	for slot in MESH_SLOTS:
		asset.mesh_files[slot] = _mesh_file_name(id, slot)
	var had_formal := FileAccess.file_exists(path)
	var document := {
		"format_version": PCGStandardAsset.FORMAT_VERSION,
		"app_version": APP_VERSION,
		"payload": asset.to_dict(),
	}
	var saved_json: Dictionary = atomic_store.save(path, JSON.stringify(document, "\t"), fault)
	if not saved_json["ok"]:
		for cleanup in written:
			DirAccess.remove_absolute(ProjectSettings.globalize_path(cleanup))
		if not had_formal:
			# 首次发布没有可恢复的正式文件，临时 JSON 一并清理，不留半成品。
			DirAccess.remove_absolute(ProjectSettings.globalize_path(path + PCGAtomicStore.TEMP_SUFFIX))
		return {"ok": false, "path": path,
			"errors": [String(saved_json.get("error", "atomic save failed"))], "manifest": manifest}
	last_publish_manifest = manifest
	return {"ok": true, "path": path, "errors": PackedStringArray(), "manifest": manifest}


## 重载一份已发布资产（含全部网格与验收报告校验）。
## 返回 {ok, asset, errors}；缺网格/缺报告/字段非法一律拒绝。
func load_asset(path: String) -> Dictionary:
	var errors: Array[String] = []
	if not FileAccess.file_exists(path):
		return {"ok": false, "asset": null, "errors": ["file not found: %s" % path]}
	var json := JSON.new()
	if json.parse(FileAccess.get_file_as_string(path)) != OK:
		return {"ok": false, "asset": null,
			"errors": ["invalid JSON in %s (line %d)" % [path, json.get_error_line()]]}
	if not (json.data is Dictionary):
		return {"ok": false, "asset": null, "errors": ["%s is not a JSON object" % path]}
	var document := json.data as Dictionary
	var version := int(document.get("format_version", 0))
	if version > PCGStandardAsset.FORMAT_VERSION:
		return {"ok": false, "asset": null,
			"errors": ["%s format_version %d is newer than supported %d"
				% [path, version, PCGStandardAsset.FORMAT_VERSION]]}
	if not (document.get("payload") is Dictionary):
		return {"ok": false, "asset": null, "errors": ["%s has no payload object" % path]}
	var asset := PCGStandardAsset.new()
	errors = asset.from_dict(document["payload"] as Dictionary)
	if not errors.is_empty():
		return {"ok": false, "asset": null, "errors": errors}
	# 验收报告缺失/非法在 from_dict 已拒；这里再确认 verdict 非 rejected。
	var verdict := StringName(String(asset.acceptance_report.get("verdict", "")))
	if verdict == &"rejected":
		return {"ok": false, "asset": null,
			"errors": ["%s acceptance verdict is \"rejected\"" % path]}
	# 逐槽位加载网格文件：缺失 → 拒绝。
	var base_dir := path.get_base_dir()
	var meshes := {}
	for slot in MESH_SLOTS:
		var mesh_file := String(asset.mesh_files.get(slot, ""))
		if mesh_file.is_empty():
			return {"ok": false, "asset": null,
				"errors": ["%s mesh_files entry \"%s\" is empty" % [path, slot]]}
		var mesh_path := base_dir + "/" + mesh_file
		if not FileAccess.file_exists(mesh_path):
			return {"ok": false, "asset": null,
				"errors": ["missing mesh file for slot \"%s\": %s" % [slot, mesh_path]]}
		var resource: Resource = ResourceLoader.load(mesh_path)
		if resource == null or not (resource is ArrayMesh) or (resource as ArrayMesh).get_surface_count() == 0:
			return {"ok": false, "asset": null,
				"errors": ["mesh file for slot \"%s\" is not a usable ArrayMesh: %s" % [slot, mesh_path]]}
		meshes[slot] = resource
	asset.normalized_mesh = meshes["lod0"]
	asset.lod1_mesh = meshes["lod1"]
	asset.lod2_mesh = meshes["lod2"]
	asset.whitebox_mesh = meshes["whitebox"]
	if not asset.material_profile_path.is_empty():
		if not FileAccess.file_exists(asset.material_profile_path):
			return {"ok": false, "asset": null,
				"errors": ["missing material profile: %s" % asset.material_profile_path]}
		var profile: Resource = ResourceLoader.load(asset.material_profile_path)
		if profile == null or not (profile is PCGMaterialProfile):
			return {"ok": false, "asset": null,
				"errors": ["material profile is not a PCGMaterialProfile: %s" % asset.material_profile_path]}
		asset.material_profile = profile
	return {"ok": true, "asset": asset, "errors": PackedStringArray()}


## 载入目录内全部已发布资产；坏文件与重复 ID 记录在 last_report，
## 重复 ID 只保留首个，绝不静默跳过。
func list_assets(asset_directory: String = "") -> Array[PCGStandardAsset]:
	last_report = []
	var assets: Array[PCGStandardAsset] = []
	var dir := _resolve_dir(asset_directory)
	var seen_ids := {}
	var dir_access := DirAccess.open(dir)
	if dir_access == null:
		last_report.append("directory not readable: %s" % dir)
		return assets
	var file_names := dir_access.get_files()
	file_names.sort()
	for file_name in file_names:
		if not file_name.ends_with(FILE_SUFFIX):
			continue
		var path := dir + "/" + file_name
		var loaded := load_asset(path)
		if not loaded["ok"]:
			last_report.append("%s: %s" % [file_name, "; ".join(loaded["errors"])])
			continue
		var asset: PCGStandardAsset = loaded["asset"]
		var id := String(asset.asset_id())
		if id.is_empty():
			last_report.append("%s: stable_id is empty" % file_name)
			continue
		if seen_ids.has(id):
			last_report.append("%s: duplicate asset id \"%s\" (already loaded from %s); skipped"
				% [file_name, id, seen_ids[id]])
			continue
		seen_ids[id] = file_name
		assets.append(asset)
	return assets


func _save_mesh_atomic(mesh: ArrayMesh, path: String) -> Error:
	# 临时文件必须带可识别扩展名（.res），否则 ResourceSaver 无法选择存储器。
	var temp_path := path.get_basename() + ".tmp." + path.get_extension()
	var err := ResourceSaver.save(mesh, temp_path)
	if err != OK:
		DirAccess.remove_absolute(ProjectSettings.globalize_path(temp_path))
		return err
	return DirAccess.rename_absolute(ProjectSettings.globalize_path(temp_path),
		ProjectSettings.globalize_path(path))


func _mesh_file_name(asset_id: String, slot: String) -> String:
	return "%s.%s%s" % [asset_id, slot, MESH_SUFFIX]


func _mesh_path(dir: String, asset_id: String, slot: String) -> String:
	return dir + "/" + _mesh_file_name(asset_id, slot)


func _face_count(mesh: ArrayMesh) -> int:
	if mesh == null:
		return 0
	var faces := 0
	for surface_index in mesh.get_surface_count():
		var arrays := mesh.surface_get_arrays(surface_index)
		var indices: PackedInt32Array = arrays[Mesh.ARRAY_INDEX]
		if indices.is_empty():
			faces += arrays[Mesh.ARRAY_VERTEX].size() / 3
		else:
			faces += indices.size() / 3
	return faces


func _resolve_dir(asset_directory: String) -> String:
	return asset_directory if not asset_directory.is_empty() else directory
