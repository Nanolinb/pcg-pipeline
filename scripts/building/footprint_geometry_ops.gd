@tool
class_name FootprintGeometryOps
extends RefCounted

# 建筑平面纯 2D 几何运算：只依赖 PackedVector2Array 与 Geometry2D，
# 不持有 plan/节点状态，供工作台与测试直接复用。

static func polygon_bounds(polygon: PackedVector2Array) -> Rect2:
	var bounds := Rect2(polygon[0], Vector2.ZERO)
	for point in polygon:
		bounds = bounds.expand(point)
	return bounds

static func plan_bounds(polygons: Array) -> Rect2:
	var bounds := Rect2()
	for polygon in polygons:
		if polygon == null or (polygon as PackedVector2Array).is_empty():
			continue
		var item := polygon_bounds(polygon)
		bounds = item if not bounds.has_area() else bounds.merge(item)
	return bounds

static func translated_shape(shape: PackedVector2Array, offset: Vector2) -> PackedVector2Array:
	var result := PackedVector2Array()
	for point in shape:
		result.append(point + offset)
	return result

static func largest_part(parts: Array) -> PackedVector2Array:
	var result := PackedVector2Array()
	var area := 0.0
	for part in parts:
		var part_area := absf(PCGBuildingFootprint.signed_area(part))
		if part_area > area:
			area = part_area
			result = part
	return result

# 选中轮廓能否融合为单一轮廓（两两 merge 都必须只产生一个部件）。
static func can_fuse(primary: PackedVector2Array, others: Array) -> bool:
	if others.is_empty():
		return false
	var merged := primary
	for other in others:
		var parts := Geometry2D.merge_polygons(merged, other)
		if parts.size() != 1:
			return false
		merged = parts[0]
	return true

# 依次合并轮廓；调用前应先经 can_fuse 确认可融合为单一轮廓。
static func fuse(primary: PackedVector2Array, others: Array) -> PackedVector2Array:
	var merged := primary
	for other in others:
		merged = Geometry2D.merge_polygons(merged, other)[0]
	return merged

# 沿中心轴切分：返回 {"first": ..., "second": ...}；无法切分时两部分均为空。
static func split_centered(polygon: PackedVector2Array) -> Dictionary:
	var bounds := polygon_bounds(polygon)
	var vertical := bounds.size.x >= bounds.size.y
	var margin := maxf(bounds.size.x, bounds.size.y) + 2.0
	var center := bounds.get_center()
	var clip := PackedVector2Array()
	if vertical:
		clip = PackedVector2Array([
			Vector2(center.x - margin, center.y - margin), Vector2(center.x, center.y - margin),
			Vector2(center.x, center.y + margin), Vector2(center.x - margin, center.y + margin),
		])
	else:
		clip = PackedVector2Array([
			Vector2(center.x - margin, center.y - margin), Vector2(center.x + margin, center.y - margin),
			Vector2(center.x + margin, center.y), Vector2(center.x - margin, center.y),
		])
	var first := largest_part(Geometry2D.intersect_polygons(polygon, clip))
	var inverse := PackedVector2Array()
	for point in clip:
		inverse.append(center * 2.0 - point)
	var second := largest_part(Geometry2D.intersect_polygons(polygon, inverse))
	if first.size() < 3 or second.size() < 3 \
			or absf(PCGBuildingFootprint.signed_area(first)) < 0.05 \
			or absf(PCGBuildingFootprint.signed_area(second)) < 0.05:
		return {"first": PackedVector2Array(), "second": PackedVector2Array()}
	return {"first": first, "second": second}

# 密度评分：既有建筑面积按高斯衰减累加，用于新建筑选址避让密集区。
static func density_at(point: Vector2, polygons: Array) -> float:
	var density := 0.0
	for polygon in polygons:
		if polygon == null or (polygon as PackedVector2Array).is_empty():
			continue
		var area := absf(PCGBuildingFootprint.signed_area(polygon))
		var center := polygon_bounds(polygon).get_center()
		var radius := 3.0 + sqrt(area) * 0.5
		var distance_sq := point.distance_squared_to(center)
		density += area * exp(-distance_sq / (2.0 * radius * radius))
	return density

static func shape_overlaps(shape: PackedVector2Array, point: Vector2, polygons: Array) -> bool:
	var candidate := translated_shape(shape, point)
	for polygon in polygons:
		if polygon == null or (polygon as PackedVector2Array).is_empty():
			continue
		for part in Geometry2D.intersect_polygons(candidate, polygon):
			if absf(PCGBuildingFootprint.signed_area(part)) > 0.001:
				return true
	return false

# 确定性布局随机流生成新建筑轮廓：低密度优先、不重叠、距中心适度。
static func density_aware_shape(random: PCGRandomStream, existing_polygons: Array) -> PackedVector2Array:
	var width := random.randf_range(1.8, 3.4)
	var depth := random.randf_range(1.6, 3.2)
	var shape := PackedVector2Array()
	if random.randf() < 0.28:
		shape = PackedVector2Array([
			Vector2(-width * 0.5, -depth * 0.5), Vector2(width * 0.5, -depth * 0.5),
			Vector2(width * 0.5, -depth * 0.1), Vector2(width * 0.1, -depth * 0.1),
			Vector2(width * 0.1, depth * 0.5), Vector2(-width * 0.5, depth * 0.5),
		])
	else:
		shape = PackedVector2Array([
			Vector2(-width * 0.5, -depth * 0.5), Vector2(width * 0.5, -depth * 0.5),
			Vector2(width * 0.5, depth * 0.5), Vector2(-width * 0.5, depth * 0.5),
		])
	var rotation := random.randf_range(-0.22, 0.22)
	for index in shape.size():
		shape[index] = shape[index].rotated(rotation)
	if existing_polygons.is_empty():
		return shape
	var bounds := plan_bounds(existing_polygons)
	var area := Rect2(bounds.position - Vector2(3.0, 3.0), bounds.size + Vector2(6.0, 6.0))
	var center := bounds.get_center()
	var best := Vector2(bounds.end.x + 2.0, center.y)
	var best_score := INF
	for candidate_index in 32:
		var point := Vector2(
			random.randf_range(area.position.x, area.end.x),
			random.randf_range(area.position.y, area.end.y)
		)
		if shape_overlaps(shape, point, existing_polygons):
			continue
		var score := density_at(point, existing_polygons) + point.distance_to(center) * 0.025 + random.randf() * 0.08
		if score < best_score:
			best_score = score
			best = point
	return translated_shape(shape, best)
