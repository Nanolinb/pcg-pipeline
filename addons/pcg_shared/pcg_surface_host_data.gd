@tool
class_name PCGSurfaceHostData
extends PCGSurfaceHost

# v0.14 公共内核：纯数据表面宿主。
# 以参数化数据实现平面 / 圆柱 / 半球圆柱三种表面，数学与根工程
# PCGFusedWall 的既有实现逐项一致（由 scripts/tests/test_surface_host.gd
# 做等价性回归），但完全不依赖 Node3D、CSG 或主程序节点类型。
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
	if surface_kind != SurfaceKind.PLANE:
		var angle := anchor.x / cylinder_radius
		if surface_kind == SurfaceKind.DOME_CYLINDER and anchor.y > cylinder_height * 0.5:
			var latitude := (anchor.y - cylinder_height * 0.5) / cylinder_radius
			var normal := Vector3(sin(angle) * cos(latitude), sin(latitude), cos(angle) * cos(latitude)).normalized()
			var point := Vector3(0.0, cylinder_height * 0.5, 0.0) + normal * cylinder_radius
			return host_transform * Transform3D(_radial_basis(angle, normal), point)
		var point := Vector3(sin(angle) * cylinder_radius, anchor.y, cos(angle) * cylinder_radius)
		var normal := Vector3(sin(angle), 0.0, cos(angle))
		return host_transform * Transform3D(_radial_basis(angle, normal), point)
	return host_transform * Transform3D(Basis.IDENTITY, Vector3(anchor.x, anchor.y, thickness * 0.5))

func _radial_basis(angle: float, normal: Vector3) -> Basis:
	var x := Vector3(cos(angle), 0.0, -sin(angle)).normalized()
	var y := normal.cross(x).normalized()
	return Basis(x, y, normal)

func surface_distance(a: Vector2, b: Vector2) -> float:
	if surface_kind != SurfaceKind.PLANE:
		var circumference := TAU * cylinder_radius
		var arc_difference := absf(a.x - b.x)
		arc_difference = minf(arc_difference, circumference - arc_difference)
		return Vector2(arc_difference, a.y - b.y).length()
	return a.distance_to(b)

## 与 PCGFusedWall.clamp_anchor 同语义，但接收组件尺寸 Vector2，
## 不依赖 PCGComponentDefinition 类型，保持共享包零主程序依赖。
func clamp_anchor(anchor: Vector2, component_size: Vector2) -> Vector2:
	if surface_kind != SurfaceKind.PLANE:
		var half_arc := PI * cylinder_radius
		var wrapped_x := fposmod(anchor.x + half_arc, half_arc * 2.0) - half_arc
		var lower := -cylinder_height * 0.5 + component_size.y * 0.5 + 0.05
		var upper := cylinder_height * 0.5 - component_size.y * 0.5 - 0.05
		if surface_kind == SurfaceKind.DOME_CYLINDER:
			upper = cylinder_height * 0.5 + cylinder_radius * PI * 0.5 - 0.05
		return Vector2(wrapped_x, clampf(anchor.y, lower, maxf(lower, upper)))
	var limits := Vector2(
		maxf(0.0, (wall_size.x - component_size.x) * 0.5 - 0.05),
		maxf(0.0, (wall_size.y - component_size.y) * 0.5 - 0.05)
	)
	return Vector2(clampf(anchor.x, -limits.x, limits.x), clampf(anchor.y, -limits.y, limits.y))

func surface_raycast(origin: Vector3, direction: Vector3) -> Dictionary:
	if surface_kind == SurfaceKind.DOME_CYLINDER:
		var cylinder_hit := _ray_cylinder(origin, direction)
		var dome_hit := _ray_dome(origin, direction)
		if cylinder_hit.is_empty():
			return dome_hit
		if dome_hit.is_empty():
			return cylinder_hit
		var cylinder_distance := origin.distance_to(cylinder_hit["position"])
		var dome_distance := origin.distance_to(dome_hit["position"])
		return dome_hit if dome_distance < cylinder_distance else cylinder_hit
	if surface_kind == SurfaceKind.CYLINDER:
		return _ray_cylinder(origin, direction)
	var normal := host_transform.basis.z.normalized()
	var plane := Plane(normal, host_transform.origin + host_transform.basis.z * thickness * 0.5)
	var point: Variant = plane.intersects_ray(origin, direction)
	if point == null:
		return {}
	var local: Vector3 = host_transform.affine_inverse() * (point as Vector3)
	if absf(local.x) > wall_size.x * 0.5 or absf(local.y) > wall_size.y * 0.5:
		return {}
	return _hit_result(Vector2(local.x, local.y), point, normal)

func _ray_cylinder(origin: Vector3, direction: Vector3) -> Dictionary:
	var local_origin := host_transform.affine_inverse() * origin
	var local_direction := host_transform.basis.inverse() * direction
	var a := local_direction.x * local_direction.x + local_direction.z * local_direction.z
	if a < 0.0000001:
		return {}
	var b := 2.0 * (local_origin.x * local_direction.x + local_origin.z * local_direction.z)
	var c := local_origin.x * local_origin.x + local_origin.z * local_origin.z - cylinder_radius * cylinder_radius
	var discriminant := b * b - 4.0 * a * c
	if discriminant < 0.0:
		return {}
	var root := sqrt(discriminant)
	var distances := [(-b - root) / (2.0 * a), (-b + root) / (2.0 * a)]
	for distance in distances:
		if distance < 0.0:
			continue
		var local_point: Vector3 = local_origin + local_direction * float(distance)
		if absf(local_point.y) > cylinder_height * 0.5:
			continue
		var local_normal := Vector3(local_point.x, 0.0, local_point.z).normalized()
		var angle := atan2(local_point.x, local_point.z)
		return _hit_result(Vector2(angle * cylinder_radius, local_point.y),
			host_transform * local_point, (host_transform.basis * local_normal).normalized())
	return {}

func _ray_dome(origin: Vector3, direction: Vector3) -> Dictionary:
	var local_origin := host_transform.affine_inverse() * origin
	var local_direction := host_transform.basis.inverse() * direction
	var center := Vector3(0.0, cylinder_height * 0.5, 0.0)
	var offset := local_origin - center
	var a := local_direction.length_squared()
	var b := 2.0 * offset.dot(local_direction)
	var c := offset.length_squared() - cylinder_radius * cylinder_radius
	var discriminant := b * b - 4.0 * a * c
	if a < 0.0000001 or discriminant < 0.0:
		return {}
	var root := sqrt(discriminant)
	var distances := [(-b - root) / (2.0 * a), (-b + root) / (2.0 * a)]
	for distance in distances:
		if distance < 0.0:
			continue
		var local_point: Vector3 = local_origin + local_direction * float(distance)
		if local_point.y < cylinder_height * 0.5 - 0.0001:
			continue
		var local_normal := (local_point - center).normalized()
		var latitude := atan2(local_point.y - center.y, Vector2(local_point.x, local_point.z).length())
		var angle := atan2(local_point.x, local_point.z)
		return _hit_result(Vector2(angle * cylinder_radius, center.y + latitude * cylinder_radius),
			host_transform * local_point, (host_transform.basis * local_normal).normalized())
	return {}

func _hit_result(anchor: Vector2, position: Vector3, normal: Vector3) -> Dictionary:
	return {"anchor": anchor, "position": position, "normal": normal, "host": self}

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
