@tool
class_name PCGSurfaceHostData
extends PCGSurfaceHost

# v0.14 公共内核：纯数据表面宿主。
# 以参数化数据实现平面 / 圆柱 / 半球圆柱三种表面；数学全部来自共享内核
# PCGSurfaceMath（addons/pcg_shared/pcg_surface_math.gd），本类只做坐标系
# 适配（host_transform）与契约面（补 "host" 键、注册表、签名输入），
# 完全不依赖 Node3D、CSG 或主程序节点类型。
# 用于证明组件与路径核心只需要宿主数据契约，不需要具体 CSG 类型。

## 宿主在“世界”中的位姿；纯数据场景由调用方维护，默认单位变换。
var host_transform: Transform3D = Transform3D.IDENTITY
## 平面墙面尺寸（x 宽、y 高、z 厚）。
var wall_size := Vector3(6.0, 4.6, 0.36)
var cylinder_radius: float = 1.35
var cylinder_height: float = 3.8
## 平面取 wall_size.z，圆柱族取 cylinder_depth（与 PCGFusedWall.thickness 一致）。
var cylinder_depth: float = 0.7

var thickness: float:
	get:
		return wall_size.z if surface_kind == SurfaceKind.PLANE else cylinder_depth

## 已注册组件锚点：component_id -> anchor，注册顺序另存。
var component_anchors: Dictionary = {}
var component_order: Array[StringName] = []

func configure_plane(size: Vector3) -> void:
	surface_kind = SurfaceKind.PLANE
	wall_size = size

func configure_cylinder(radius: float, height: float, depth: float, dome: bool) -> void:
	surface_kind = SurfaceKind.DOME_CYLINDER if dome else SurfaceKind.CYLINDER
	cylinder_radius = radius
	cylinder_height = height
	cylinder_depth = depth

func surface_transform(anchor: Vector2) -> Transform3D:
	return PCGSurfaceMath.surface_transform(surface_kind, anchor, host_transform,
		wall_size, cylinder_radius, cylinder_height, thickness)

func surface_distance(a: Vector2, b: Vector2) -> float:
	return PCGSurfaceMath.surface_distance(surface_kind, a, b, cylinder_radius)

## 与 PCGFusedWall.clamp_anchor 同语义，但接收组件尺寸 Vector2，
## 不依赖 PCGComponentDefinition 类型，保持共享包零主程序依赖。
func clamp_anchor(anchor: Vector2, component_size: Vector2) -> Vector2:
	return PCGSurfaceMath.clamp_anchor(surface_kind, anchor, component_size,
		wall_size, cylinder_radius, cylinder_height)

func surface_raycast(origin: Vector3, direction: Vector3) -> Dictionary:
	var hit := PCGSurfaceMath.raycast(surface_kind, origin, direction, host_transform,
		wall_size, cylinder_radius, cylinder_height, thickness)
	if hit.is_empty():
		return {}
	hit["host"] = self
	return hit

func register_component(component_id: StringName, anchor: Vector2) -> void:
	if component_id == &"":
		push_error("PCGSurfaceHostData.register_component: empty component_id")
		return
	if not component_anchors.has(component_id):
		component_order.append(component_id)
	component_anchors[component_id] = anchor

func unregister_component(component_id: StringName) -> void:
	component_anchors.erase(component_id)
	component_order.erase(component_id)

func occupancy_query(_region: Dictionary) -> Array:
	# v0.14：结构稳定的空结果；v0.17 占用契约冻结后在此返回实体占用。
	return []

func host_signature_inputs() -> Dictionary:
	# 影响主体几何的输入，供 v0.14 重建签名（RebuildSignature.host_signature）采样。
	return {
		"surface_kind": surface_kind,
		"wall_size": [wall_size.x, wall_size.y, wall_size.z],
		"cylinder_radius": cylinder_radius,
		"cylinder_height": cylinder_height,
		"cylinder_depth": cylinder_depth,
	}
