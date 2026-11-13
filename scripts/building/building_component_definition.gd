@tool
class_name PCGBuildingComponentDefinition
extends Resource

const MeshFactory = preload("res://scripts/building/building_mesh_factory.gd")

enum Role {
	WINDOW,
	DOOR,
	PARAPET,
	CORNER_POST,
	AWNING,
	ROOF_HATCH,
	ROOF_DRYING_RACK,
	WINDOW_DRYING_ROD,
	BALCONY,
	DOUBLE_DOOR,
	SKYBRIDGE,
}

enum Geometry {
	BOX,
	FRAME,
	DOOR,
	PARAPET,
	AWNING,
	ROOF_HATCH,
	ROOF_DRYING_RACK,
	WINDOW_DRYING_ROD,
	WINDOW_DRYING_CLOTHES,
	BALCONY,
	DOUBLE_DOOR,
	SKYBRIDGE,
}

@export var id: StringName = &""
@export var display_name: String = "未命名建筑组件"
@export var category: String = "建筑"
@export var role: Role = Role.WINDOW
@export var geometry: Geometry = Geometry.BOX
@export var size := Vector3.ONE
@export var frame_width: float = 0.1
@export var color := Color("c88d62")
@export var accent_color := Color("385b63")
@export var material_id: StringName = &"building/component"
@export var accent_material_id: StringName = &"building/component_accent"
@export var custom_mesh: Mesh

var _generated_mesh: Mesh

func get_mesh() -> Mesh:
	if custom_mesh != null:
		return custom_mesh
	if _generated_mesh == null:
		_generated_mesh = MeshFactory.component(self)
	return _generated_mesh

func validation_errors() -> PackedStringArray:
	var errors := PackedStringArray()
	if id.is_empty():
		errors.append("组件 ID 不能为空。")
	if display_name.strip_edges().is_empty():
		errors.append("组件显示名不能为空。")
	if size.x <= 0.0 or size.y <= 0.0 or size.z <= 0.0:
		errors.append("组件尺寸三轴必须大于 0。")
	if frame_width <= 0.0:
		errors.append("框架宽度必须大于 0。")
	if geometry in [Geometry.FRAME, Geometry.DOOR] and frame_width * 2.0 >= minf(size.x, size.y):
		errors.append("框架宽度必须小于组件短边的一半。")
	if material_id.is_empty():
		errors.append("主材质 ID 不能为空。")
	if get_mesh() == null or get_mesh().get_surface_count() == 0:
		errors.append("组件必须提供可生成的封闭 Mesh。")
	return errors
