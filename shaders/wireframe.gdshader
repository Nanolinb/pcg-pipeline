shader_type spatial;
render_mode unshaded, cull_disabled, shadows_disabled;

uniform vec4 line_color : source_color = vec4(0.55, 1.0, 0.82, 1.0);
uniform vec4 fill_color : source_color = vec4(0.025, 0.05, 0.06, 1.0);
uniform float line_width = 1.25;

void fragment() {
	vec3 barycentric = vec3(UV2.x, UV2.y, 1.0 - UV2.x - UV2.y);
	vec3 interior = smoothstep(vec3(0.0), fwidth(barycentric) * line_width, barycentric);
	float fill = min(interior.x, min(interior.y, interior.z));
	ALBEDO = mix(line_color.rgb, fill_color.rgb, fill);
}
