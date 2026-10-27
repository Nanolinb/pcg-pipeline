class_name PCGComponentCatalog
extends RefCounted

var definitions: Array[PCGComponentDefinition] = []
var errors: PackedStringArray = []
var _by_id: Dictionary = {}

func load_from(directory: String) -> void:
	definitions.clear()
	errors.clear()
	_by_id.clear()
	if not DirAccess.dir_exists_absolute(directory):
		errors.append("组件目录不存在：%s" % directory)
		return
	var files := DirAccess.get_files_at(directory)
	files.sort()
	for file in files:
		if not file.ends_with(".tres"):
			continue
		var resource := ResourceLoader.load(directory.path_join(file))
		if not resource is PCGComponentDefinition:
			errors.append("%s 不是 PCGComponentDefinition。" % file)
			continue
		var definition: PCGComponentDefinition = resource
		var issues := definition.validation_errors()
		if not issues.is_empty():
			for issue in issues:
				errors.append("%s：%s" % [file, issue])
			continue
		if _by_id.has(definition.id):
			errors.append("重复组件 ID：%s。" % definition.id)
			continue
		definitions.append(definition)
		_by_id[definition.id] = definition

func get_definition(id: StringName) -> PCGComponentDefinition:
	return _by_id.get(id) as PCGComponentDefinition

func in_category(category: String) -> Array[PCGComponentDefinition]:
	var result: Array[PCGComponentDefinition] = []
	for definition in definitions:
		if definition.category == category:
			result.append(definition)
	return result
