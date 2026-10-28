shader_type spatial;
render_mode diffuse_burley, specular_schlick_ggx;

uniform vec4 tint : source_color = vec4(1.0);
uniform sampler2D base_texture : source_color, filter_linear_mipmap, repeat_enable;
uniform sampler2D detail_texture : source_color, filter_linear_mipmap, repeat_enable;
uniform sampler2D detail_normal_texture : hint_normal, filter_linear_mipmap, repeat_enable;
uniform sampler2D orm_texture : filter_linear_mipmap, repeat_enable;
uniform bool use_base_texture = false;
uniform bool use_detail_texture = false;
uniform bool use_normal_texture = false;
uniform bool use_orm_texture = false;
uniform float detail_tiling = 6.0;
uniform float detail_strength = 0.28;
uniform float normal_strength = 0.55;
uniform float roughness_amount = 0.5;
uniform float metallic_amount = 0.0;

void fragment() {
	vec3 base = tint.rgb;
	if (use_base_texture) {
		base *= texture(base_texture, UV).rgb;
	}
	if (use_detail_texture) {
		vec3 detail = texture(detail_texture, UV * detail_tiling).rgb;
		base *= mix(vec3(1.0), detail * 1.35, detail_strength);
	}
	ALBEDO = base;
	if (use_normal_texture) {
		NORMAL_MAP = texture(detail_normal_texture, UV * detail_tiling).rgb;
		NORMAL_MAP_DEPTH = normal_strength;
	}
	if (use_orm_texture) {
		vec3 orm = texture(orm_texture, UV).rgb;
		AO = orm.r;
		ROUGHNESS = orm.g;
		METALLIC = orm.b;
	} else {
		ROUGHNESS = roughness_amount;
		METALLIC = metallic_amount;
	}
}
