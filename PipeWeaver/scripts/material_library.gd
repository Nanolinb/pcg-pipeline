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

func profile_shader(id: StringName, shader_resource: Shader, profile: PCGMaterialProfile, fallbacks: Dictionary = {}, extra_parameters: Dictionary = {}, uv_policy: StringName = &"preserve", texture_world_size: float = 1.0) -> ShaderMaterial:
	var material := _materials.get(id) as ShaderMaterial
	if material == null:
		material = ShaderMaterial.new()
		material.shader = shader_resource
	var base := profile.base_color_texture if profile.base_color_texture != null else fallbacks.get(&"base_color") as Texture2D
	var detail := profile.detail_texture if profile.detail_texture != null else fallbacks.get(&"detail") as Texture2D
	var normal := profile.normal_texture if profile.normal_texture != null else fallbacks.get(&"normal") as Texture2D
	var orm := profile.orm_texture if profile.orm_texture != null else fallbacks.get(&"orm") as Texture2D
	var parameters := {
		"tint": profile.tint,
		"base_texture": base,
		"detail_texture": detail,
		"detail_normal_texture": normal,
		"orm_texture": orm,
		"use_base_texture": base != null,
		"use_detail_texture": detail != null,
		"use_normal_texture": normal != null,
		"use_orm_texture": orm != null,
		"detail_tiling": profile.detail_tiling,
		"detail_strength": profile.detail_strength,
		"normal_strength": profile.normal_strength,
		"roughness_amount": profile.roughness,
		"metallic_amount": profile.metallic,
	}
	parameters.merge(extra_parameters, true)
	for parameter in parameters:
		material.set_shader_parameter(parameter, parameters[parameter])
	if not _materials.has(id):
		_register(material, id, uv_policy, texture_world_size)
	return material

func batch_key(material: Material) -> StringName:
	if material == null:
		return &"unassigned"
	return material.get_meta("material_id", StringName("instance_%d" % material.get_instance_id())) as StringName

func update_shaders(id_prefix: StringName, parameters: Dictionary) -> void:
	for id in _materials:
		if not String(id).begins_with(String(id_prefix)):
			continue
		var material := _materials[id] as ShaderMaterial
		if material == null:
			continue
		for parameter in parameters:
			material.set_shader_parameter(parameter, parameters[parameter])

func unique_material_count() -> int:
	return _materials.size()

func _register(material: Material, id: StringName, uv_policy: StringName = &"preserve", texture_world_size: float = 1.0) -> void:
	material.set_meta("material_id", id)
	material.set_meta("uv_policy", uv_policy)
	material.set_meta("texture_world_size", texture_world_size)
	_materials[id] = material
