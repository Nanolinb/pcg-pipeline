extends Node

var _materials: Dictionary = {}

func solid(id: StringName, color: Color, roughness: float, metallic: float = 0.0, uv_policy: StringName = &"preserve", texture_world_size: float = 1.0) -> StandardMaterial3D:
	if _materials.has(id):
		return _materials[id] as StandardMaterial3D
	var material := StandardMaterial3D.new()
	material.albedo_color = color
	material.roughness = roughness
	material.metallic = metallic
	_register(material, id, uv_policy, texture_world_size)
	return material

func unshaded(id: StringName, color: Color, no_depth_test: bool = true, transparent: bool = false, additive: bool = false, cull_mode: BaseMaterial3D.CullMode = BaseMaterial3D.CULL_BACK) -> StandardMaterial3D:
	if _materials.has(id):
		return _materials[id] as StandardMaterial3D
	var material := StandardMaterial3D.new()
	material.albedo_color = color
	material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	material.no_depth_test = no_depth_test
	material.cull_mode = cull_mode
	if transparent:
		material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	if additive:
		material.blend_mode = BaseMaterial3D.BLEND_MODE_ADD
	_register(material, id)
	return material

func shader(id: StringName, shader_resource: Shader, parameters: Dictionary = {}, uv_policy: StringName = &"preserve", texture_world_size: float = 1.0) -> ShaderMaterial:
	if _materials.has(id):
		return _materials[id] as ShaderMaterial
	var material := ShaderMaterial.new()
	material.shader = shader_resource
	for parameter in parameters:
		material.set_shader_parameter(parameter, parameters[parameter])
	_register(material, id, uv_policy, texture_world_size)
	return material

func batch_key(material: Material) -> StringName:
	if material == null:
		return &"unassigned"
	return material.get_meta("material_id", StringName("instance_%d" % material.get_instance_id())) as StringName

func unique_material_count() -> int:
	return _materials.size()

func _register(material: Material, id: StringName, uv_policy: StringName = &"preserve", texture_world_size: float = 1.0) -> void:
	material.set_meta("material_id", id)
	material.set_meta("uv_policy", uv_policy)
	material.set_meta("texture_world_size", texture_world_size)
	_materials[id] = material
