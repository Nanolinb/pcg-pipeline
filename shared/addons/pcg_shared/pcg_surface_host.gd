@tool
class_name PCGSurfaceHost
extends RefCounted

# v0.14 公共内核：表面宿主契约（docs/core_contracts.md §4）。
# 只定义宿主能力边界，不引用任何具体 CSG 节点或主程序节点类型；
# 纯数据宿主直接继承本类，节点宿主（如根工程 PCGFusedWall）以结构化方式
# 实现同一组方法（GDScript 单继承限制，节点适配器无法同时继承 RefCounted）。
#
# 语义约定：
# - 锚点使用宿主局部表面坐标（平面为墙面 xy，圆柱为展开弧长/高度）；
#   世界坐标只允许出现在适配器边界。
# - surface_kind 只允许追加枚举值，不得改变已有值的含义。
# - host_path_data / occupancy_query 在 v0.14 允许返回空数据，
#   但返回结构必须稳定（字典键与数组类型固定）。

enum SurfaceKind {
	PLANE,
	CYLINDER,
	DOME_CYLINDER,
}

## 稳定宿主 ID；发布后不变，规则同 docs/core_contracts.md §1.1。
var host_id: StringName = &""
## 宿主表面种类，取值仅限 SurfaceKind 枚举；只允许追加。
var surface_kind: int = SurfaceKind.PLANE

## 锚点 → 世界变换。基类未实现，由具体宿主覆盖。
func surface_transform(anchor: Vector2) -> Transform3D:
	push_error("PCGSurfaceHost.surface_transform: host %s does not implement the contract" % host_id)
	return Transform3D.IDENTITY

## 两个锚点之间的沿表面测地距离。
func surface_distance(a: Vector2, b: Vector2) -> float:
	push_error("PCGSurfaceHost.surface_distance: host %s does not implement the contract" % host_id)
	return 0.0

## 世界射线 → 表面锚点。返回字典结构稳定：
## 命中时 {"anchor": Vector2, "position": Vector3, "normal": Vector3, "host": 宿主}，
## 未命中时返回空字典。
func surface_raycast(origin: Vector3, direction: Vector3) -> Dictionary:
	push_error("PCGSurfaceHost.surface_raycast: host %s does not implement the contract" % host_id)
	return {}

## 锚点处的表面标架；默认由 surface_transform 派生，宿主一般无需覆盖。
## 结构稳定：{"position", "normal", "tangent", "bitangent", "anchor", "host"}。
func surface_frame(anchor: Vector2) -> Dictionary:
	var frame_transform := surface_transform(anchor)
	var basis := frame_transform.basis
	return {
		"position": frame_transform.origin,
		"normal": basis.z.normalized(),
		"tangent": basis.x.normalized(),
		"bitangent": basis.y.normalized(),
		"anchor": anchor,
		"host": self,
	}

## 路径数据出口。v0.14 允许为空，但键结构稳定。
func host_path_data() -> Dictionary:
	return {
		"host_id": host_id,
		"surface_kind": surface_kind,
		"coordinate": "surface_local",
		"paths": [],
	}

## 占用查询。v0.14 允许返回空数组，但返回类型必须是 Array。
func occupancy_query(_region: Dictionary) -> Array:
	return []

## 注册组件锚点。节点适配器可以用组件句柄覆盖同名方法（见类注释）。
func register_component(component_id: StringName, anchor: Vector2) -> void:
	push_error("PCGSurfaceHost.register_component: host %s does not implement the contract" % host_id)

## 注销组件锚点。
func unregister_component(component_id: StringName) -> void:
	push_error("PCGSurfaceHost.unregister_component: host %s does not implement the contract" % host_id)

## 契约校验：返回缺失或未实现的成员名列表；空数组表示满足宿主契约。
static func validate_surface_host(candidate: Object) -> Array[String]:
	var problems: Array[String] = []
	if candidate == null:
		problems.append("candidate is null")
		return problems
	var required := {
		"surface_transform": 1,
		"surface_distance": 2,
		"surface_raycast": 2,
		"surface_frame": 1,
		"host_path_data": 0,
		"occupancy_query": 1,
		"register_component": 2,
		"unregister_component": 1,
	}
	for method_name in required:
		if not candidate.has_method(method_name):
			problems.append("missing method: " + method_name)
	return problems
