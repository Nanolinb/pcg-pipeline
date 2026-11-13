@tool
class_name PCGBuildingComponentCatalog
extends RefCounted

const Definition = preload("res://scripts/building/building_component_definition.gd")

var definitions: Array[PCGBuildingComponentDefinition] = []
var errors := PackedStringArray()
var _by_id: Dictionary = {}

func load_from(directory: String) -> void:
	definitions.clear()
	errors.clear()
	_by_id.clear()
	if not DirAccess.dir_exists_absolute(directory):
		errors.append("建筑组件目录不存在：%s" % directory)
		return
	var files := DirAccess.get_files_at(directory)
	files.sort()
	for file in files:
		if not file.ends_with(".tres"):
			continue
		var resource := ResourceLoader.load(directory.path_join(file))
		if not resource is PCGBuildingComponentDefinition:
			errors.append("%s 不是建筑组件定义。" % file)
			continue
		var definition: PCGBuildingComponentDefinition = resource
		var issues := definition.validation_errors()
		for issue in issues:
			errors.append("%s：%s" % [file, issue])
		if not issues.is_empty():
			continue
		if _by_id.has(definition.id):
			errors.append("重复建筑组件 ID：%s。" % definition.id)
			continue
		definitions.append(definition)
		_by_id[definition.id] = definition

func get_definition(id: StringName) -> PCGBuildingComponentDefinition:
	return _by_id.get(id) as PCGBuildingComponentDefinition

func default_for_role(role: Definition.Role) -> PCGBuildingComponentDefinition:
	for definition in definitions:
		if definition.role == role:
			return definition
	return null

func in_role(role: Definition.Role) -> Array[PCGBuildingComponentDefinition]:
	var result: Array[PCGBuildingComponentDefinition] = []
	for definition in definitions:
		if definition.role == role:
			result.append(definition)
	return result

func binding_errors(footprint: PCGBuildingFootprint) -> PackedStringArray:
	var issues := PackedStringArray()
	var bindings := [
		[footprint.window_component_id, Definition.Role.WINDOW],
		[footprint.door_component_id, Definition.Role.DOOR],
		[footprint.parapet_component_id, Definition.Role.PARAPET],
		[footprint.corner_component_id, Definition.Role.CORNER_POST],
		[footprint.awning_component_id, Definition.Role.AWNING],
		[footprint.roof_component_id, Definition.Role.ROOF_HATCH],
		[footprint.roof_drying_component_id, Definition.Role.ROOF_DRYING_RACK],
		[footprint.balcony_component_id, Definition.Role.BALCONY],
		[footprint.double_door_component_id, Definition.Role.DOUBLE_DOOR],
	]
	for binding in bindings:
		var definition := get_definition(binding[0])
		if definition == null:
			issues.append("%s：缺少组件 %s。" % [footprint.id, binding[0]])
		elif definition.role != binding[1]:
			issues.append("%s：组件 %s 的角色不匹配。" % [footprint.id, binding[0]])
	if in_role(Definition.Role.WINDOW_DRYING_ROD).is_empty():
		issues.append("%s：缺少窗外晾衣杆组件。" % footprint.id)
	return issues
