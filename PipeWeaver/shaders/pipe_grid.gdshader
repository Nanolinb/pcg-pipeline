shader_type spatial;
render_mode diffuse_burley, specular_schlick_ggx;

uniform vec4 tint : source_color = vec4(1.0);
uniform sampler2D base_texture : source_color, filter_linear_mipmap, repeat_enable;
uniform sampler2D detail_texture : source_color, filter_linear_mipmap, repeat_enable;
uniform sampler2D detail_normal_texture : hint_normal, filter_linear_mipmap, repeat_enable;
uniform sampler2D orm_texture : filter_linear_mipmap, repeat_enable;
uniform sampler2D ao_texture : filter_linear_mipmap, repeat_disable;
uniform float detail_tiling = 6.0;
uniform float detail_strength = 0.28;
uniform float normal_strength = 0.55;
uniform float ao_strength = 0.0;

void fragment() {
	vec3 base = tint.rgb * texture(base_texture, UV).rgb;
	vec3 detail = texture(detail_texture, UV * detail_tiling).rgb;
	vec3 orm = texture(orm_texture, UV).rgb;
	vec3 baked_ao = texture(ao_texture, UV2).rgb;
	ALBEDO = base * mix(vec3(1.0), detail * 1.35, detail_strength);
	ROUGHNESS = clamp(orm.g, 0.06, 1.0);
	METALLIC = orm.b;
	AO = orm.r * mix(1.0, baked_ao.r, ao_strength);
	AO_LIGHT_AFFECT = 1.0;
	NORMAL_MAP = texture(detail_normal_texture, UV * detail_tiling).rgb;
	NORMAL_MAP_DEPTH = normal_strength;
}
