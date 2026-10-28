class_name PCGComponentDefinition
extends Resource

enum Shape {
	ROUND_WINDOW,
	SQUARE_WINDOW,
}

@export var id: StringName = &""
@export var display_name: String = "未命名组件"
@export var category: String = "窗户"
@export var shape: Shape = Shape.ROUND_WINDOW
@export var size: Vector2 = Vector2.ONE
@export var depth: float = 0.32
@export_range(0.02, 0.5, 0.01) var root_embed: float = 0.12
@export_range(0.0, 0.5, 0.01) var root_flare: float = 0.18
@export var transition_enabled: bool = true
@export_range(-1.0, 1.0, 0.01) var transition_thickness: float = -1.0
@export_range(0.0, 1.0, 0.05) var transition_curvature: float = 0.65
@export_range(-90.0, 90.0, 1.0) var attachment_angle_degrees: float = 0.0
@export var frame_width: float = 0.14
@export_range(0.05, 1.0, 0.01) var min_scale: float = 0.35
@export var overlap_gap: float = 0.04
@export var priority: int = 0
@export var frame_color: Color = Color("e99472")
@export var glass_color: Color = Color("47777c")
@export var frame_material_id: StringName = &"window_frame"
@export var glass_material_id: StringName = &"window_glass"
@export var frame_profile: PCGMaterialProfile
@export var glass_profile: PCGMaterialProfile
@export_range(0.1, 8.0, 0.05) var texture_world_size: float = 0.65
@export var custom_frame_mesh: Mesh

func footprint_radius() -> float:
	if shape == Shape.ROUND_WINDOW:
		return maxf(size.x, size.y) * 0.5 * (1.0 + root_flare)
	return size.length() * 0.5

func opening_size() -> Vector2:
	return Vector2(
		maxf(size.x - frame_width * 2.0, 0.05),
		maxf(size.y - frame_width * 2.0, 0.05)
	)

func validation_errors() -> PackedStringArray:
	var errors := PackedStringArray()
	if id.is_empty():
		errors.append("组件 ID 不能为空。")
	if size.x <= 0.0 or size.y <= 0.0:
		errors.append("组件尺寸必须大于 0。")
	if depth <= 0.02:
		errors.append("组件深度必须大于 0.02。")
	if frame_width <= 0.0 or frame_width * 2.0 >= minf(size.x, size.y):
		errors.append("窗框宽度必须为有效值。")
	if frame_material_id.is_empty() or glass_material_id.is_empty():
		errors.append("框架与玻璃必须指定共享材质 ID。")
	if texture_world_size <= 0.0:
		errors.append("贴图世界尺寸必须大于 0。")
	if custom_frame_mesh != null and shape != Shape.ROUND_WINDOW:
		errors.append("当前自定义窗框 Mesh 入口仅用于圆形窗。")
	return errors
