@tool
class_name PCGSurfaceMath
extends RefCounted

# v0.14 公共内核：表面数学纯函数内核。
# 以纯静态函数实现平面 / 圆柱 / 半球圆柱三种表面的锚点变换、沿表面
# 测地距离、锚点钳制与世界射线求交；不依赖任何 Node/CSG/宿主类型，
# 宿主位姿一律由调用方以 Transform3D 显式传入。
# 宿主适配层（PCGSurfaceHostData 纯数据宿主、根工程 PCGFusedWall 节点
# 适配器）只负责传入自身坐标系位姿并补 "host" 键，数学必须来自本内核，
# 由 scripts/tests/surface_host_test_runner.gd 做内核已知值锚定与等价回归。

## 表面种类取值，与 PCGSurfaceHost.SurfaceKind 逐项一致（契约只允许追加）。
const KIND_PLANE := 0
const KIND_CYLINDER := 1
const KIND_DOME_CYLINDER := 2

## 锚点 → 世界变换。host_transform 为宿主在“世界”中的位姿，
## thickness 为表面厚度（平面取 wall_size.z，圆柱族取 cylinder_depth）。
static func surface_transform(surface_kind: int, anchor: Vector2, host_transform: Transform3D,
		wall_size: Vector3, cylinder_radius: float, cylinder_height: float, thickness: float) -> Transform3D:
	if surface_kind != KIND_PLANE:
		var angle := anchor.x / cylinder_radius
		if surface_kind == KIND_DOME_CYLINDER and anchor.y > cylinder_height * 0.5:
			var latitude := (anchor.y - cylinder_height * 0.5) / cylinder_radius
			var normal := Vector3(sin(angle) * cos(latitude), sin(latitude), cos(angle) * cos(latitude)).normalized()
			var point := Vector3(0.0, cylinder_height * 0.5, 0.0) + normal * cylinder_radius
			return host_transform * Transform3D(_radial_basis(angle, normal), point)
		var point := Vector3(sin(angle) * cylinder_radius, anchor.y, cos(angle) * cylinder_radius)
		var normal := Vector3(sin(angle), 0.0, cos(angle))
		return host_transform * Transform3D(_radial_basis(angle, normal), point)
	return host_transform * Transform3D(Basis.IDENTITY, Vector3(anchor.x, anchor.y, thickness * 0.5))

static func _radial_basis(angle: float, normal: Vector3) -> Basis:
	var x := Vector3(cos(angle), 0.0, -sin(angle)).normalized()
	var y := normal.cross(x).normalized()
	return Basis(x, y, normal)

## 两个锚点之间的沿表面测地距离（圆柱族沿周长取短弧）。
static func surface_distance(surface_kind: int, a: Vector2, b: Vector2, cylinder_radius: float) -> float:
	if surface_kind != KIND_PLANE:
		var circumference := TAU * cylinder_radius
		var arc_difference := absf(a.x - b.x)
		arc_difference = minf(arc_difference, circumference - arc_difference)
		return Vector2(arc_difference, a.y - b.y).length()
	return a.distance_to(b)

## 锚点钳制：平面收进墙面内缩边界，圆柱族弧长回绕 ±half_arc 并收进高度带；
## 半球圆柱上界含穹顶弧长。component_size 为组件尺寸 Vector2。
static func clamp_anchor(surface_kind: int, anchor: Vector2, component_size: Vector2,
		wall_size: Vector3, cylinder_radius: float, cylinder_height: float) -> Vector2:
	if surface_kind != KIND_PLANE:
		var half_arc := PI * cylinder_radius
		var wrapped_x := fposmod(anchor.x + half_arc, half_arc * 2.0) - half_arc
		var lower := -cylinder_height * 0.5 + component_size.y * 0.5 + 0.05
		var upper := cylinder_height * 0.5 - component_size.y * 0.5 - 0.05
		if surface_kind == KIND_DOME_CYLINDER:
			upper = cylinder_height * 0.5 + cylinder_radius * PI * 0.5 - 0.05
		return Vector2(wrapped_x, clampf(anchor.y, lower, maxf(lower, upper)))
	var limits := Vector2(
		maxf(0.0, (wall_size.x - component_size.x) * 0.5 - 0.05),
		maxf(0.0, (wall_size.y - component_size.y) * 0.5 - 0.05)
	)
	return Vector2(clampf(anchor.x, -limits.x, limits.x), clampf(anchor.y, -limits.y, limits.y))

## 世界射线 → 表面锚点。命中时返回 {"anchor": Vector2, "position": Vector3,
## "normal": Vector3}（不含 "host" 键，由宿主适配层补齐），未命中返回空字典。
static func raycast(surface_kind: int, origin: Vector3, direction: Vector3,
		host_transform: Transform3D, wall_size: Vector3,
		cylinder_radius: float, cylinder_height: float, thickness: float) -> Dictionary:
	if surface_kind == KIND_DOME_CYLINDER:
		var cylinder_hit := _ray_cylinder(origin, direction, host_transform, cylinder_radius, cylinder_height)
		var dome_hit := _ray_dome(origin, direction, host_transform, cylinder_radius, cylinder_height)
		if cylinder_hit.is_empty():
			return dome_hit
		if dome_hit.is_empty():
			return cylinder_hit
		var cylinder_distance := origin.distance_to(cylinder_hit["position"])
		var dome_distance := origin.distance_to(dome_hit["position"])
		return dome_hit if dome_distance < cylinder_distance else cylinder_hit
	if surface_kind == KIND_CYLINDER:
		return _ray_cylinder(origin, direction, host_transform, cylinder_radius, cylinder_height)
	var normal := host_transform.basis.z.normalized()
	var plane := Plane(normal, host_transform.origin + host_transform.basis.z * thickness * 0.5)
	var point: Variant = plane.intersects_ray(origin, direction)
	if point == null:
		return {}
	var local: Vector3 = host_transform.affine_inverse() * (point as Vector3)
	if absf(local.x) > wall_size.x * 0.5 or absf(local.y) > wall_size.y * 0.5:
		return {}
	return {"anchor": Vector2(local.x, local.y), "position": point, "normal": normal}

static func _ray_cylinder(origin: Vector3, direction: Vector3,
		host_transform: Transform3D, cylinder_radius: float, cylinder_height: float) -> Dictionary:
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
		return {
			"anchor": Vector2(angle * cylinder_radius, local_point.y),
			"position": host_transform * local_point,
			"normal": (host_transform.basis * local_normal).normalized(),
		}
	return {}

static func _ray_dome(origin: Vector3, direction: Vector3,
		host_transform: Transform3D, cylinder_radius: float, cylinder_height: float) -> Dictionary:
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
		return {
			"anchor": Vector2(angle * cylinder_radius, center.y + latitude * cylinder_radius),
			"position": host_transform * local_point,
			"normal": (host_transform.basis * local_normal).normalized(),
		}
	return {}
