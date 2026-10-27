shader_type spatial;
render_mode diffuse_burley, specular_schlick_ggx;

uniform vec4 base_color : source_color = vec4(0.24, 0.48, 0.55, 1.0);
uniform vec4 grid_color : source_color = vec4(0.08, 0.16, 0.19, 1.0);
uniform float metallic_amount = 0.55;
uniform float roughness_amount = 0.38;

void fragment() {
	vec2 width = max(fwidth(UV), vec2(0.0001));
	vec2 grid = abs(fract(UV - vec2(0.5)) - vec2(0.5)) / width;
	float line = 1.0 - min(min(grid.x, grid.y), 1.0);
	ALBEDO = mix(base_color.rgb, grid_color.rgb, line * 0.72);
	METALLIC = metallic_amount;
	ROUGHNESS = roughness_amount + line * 0.12;
}
