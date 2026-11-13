@tool
class_name PCGBuildingGenerator
extends RefCounted

const Definition = preload("res://scripts/building/building_component_definition.gd")
const MeshFactory = preload("res://scripts/building/building_mesh_factory.gd")
const MeshBuildUtil = preload("res://addons/pcg_shared/mesh_build_util.gd")

func build_plan(plan: PCGBuildingPlan, catalog: PCGBuildingComponentCatalog) -> Dictionary:
	var errors := plan.validation_errors()
	for footprint in plan.footprints:
		if footprint != null:
			errors.append_array(catalog.binding_errors(footprint))
	if not errors.is_empty():
		return {"root": null, "errors": errors, "buildings": [], "stats": {}}
	var root := Node3D.new()
	root.name = "GeneratedBuildingPlan"
	var buildings: Array[Node3D] = []
	var component_count := 0
	var triangle_count := 0
	for footprint in plan.footprints:
		var result := build_building(footprint, plan.master_seed, catalog, plan.footprints,
			plan.facade_exclusions_for(footprint.id), plan, plan.connectors_for_building(footprint.id))
		if not result["errors"].is_empty():
			root.free()
			return {"root": null, "errors": result["errors"], "buildings": [], "stats": {}}
		var building: Node3D = result["root"]
		root.add_child(building)
		buildings.append(building)
		component_count += int(building.get_meta("component_count"))
		triangle_count += int(building.get_meta("triangle_count"))
	return {
		"root": root,
		"errors": PackedStringArray(),
		"buildings": buildings,
		"stats": {
			"buildings": buildings.size(),
			"components": component_count,
			"triangles": triangle_count,
			"digest": PCGCanonicalSerializer.hash_document(plan.semantic_data()),
		},
	}

func build_building(footprint: PCGBuildingFootprint, master_seed: String,
			catalog: PCGBuildingComponentCatalog, obstacles: Array = [],
			facade_exclusions: Array = [], terrain: PCGBuildingPlan = null,
			connectors: Array = []) -> Dictionary:
	var errors := footprint.validation_errors()
	errors.append_array(catalog.binding_errors(footprint))
	if not errors.is_empty():
		return {"root": null, "errors": errors}
	var polygon := footprint.normalized_polygon()
	var height := footprint.height()
	var base_elevation := _base_elevation(polygon, terrain)
	footprint.ground_elevation = base_elevation
	var root := Node3D.new()
	root.name = "Building_%s" % footprint.id
	root.position.y = base_elevation
	root.set_meta("footprint_id", footprint.id)
	root.set_meta("base_elevation", base_elevation)
	if terrain != null and not terrain.terrain_slope.is_zero_approx():
		var foundation := MeshInstance3D.new()
		foundation.name = "SlopeFoundation"
		foundation.mesh = MeshFactory.foundation(polygon, terrain, base_elevation)
		foundation.material_override = preload("res://addons/pcg_shared/pcg_material_access.gd").library().solid(&"building/foundation", Color("675f52"), 0.94)
		root.add_child(foundation)
	var body := MeshInstance3D.new()
	body.name = "DerivedSolid"
	body.mesh = MeshFactory.extrude(polygon, height, _facade_openings(footprint, polygon, height, connectors))
	body.material_override = preload("res://addons/pcg_shared/pcg_material_access.gd").library().solid(
		footprint.wall_material_id, footprint.wall_color, 0.88, 0.0, &"preserve", 1.0
	)
	body.set_meta("footprint_id", footprint.id)
	root.add_child(body)
	var components := Node3D.new()
	components.name = "StandardComponents"
	root.add_child(components)
	var random := PCGDeterministicRng.create_stream(master_seed, {
		"building": footprint.id, "purpose": &"detail",
	})
	var window := catalog.get_definition(footprint.window_component_id)
	var door := catalog.get_definition(footprint.double_door_component_id) if footprint.use_double_entrance else catalog.get_definition(footprint.door_component_id)
	var parapet := catalog.get_definition(footprint.parapet_component_id)
	var corner := catalog.get_definition(footprint.corner_component_id)
	var awning := catalog.get_definition(footprint.awning_component_id)
	var roof := catalog.get_definition(footprint.roof_component_id)
	var roof_drying := catalog.get_definition(footprint.roof_drying_component_id)
	var balcony := catalog.get_definition(footprint.balcony_component_id)
	var drying_variants := catalog.in_role(Definition.Role.WINDOW_DRYING_ROD)
	var entrance := _choose_entrance(polygon, door, window, footprint.id, obstacles, base_elevation)
	var occupied: Array[Dictionary] = []
	if entrance.has("bounds"):
		occupied.append({"bounds": entrance["bounds"], "host_id": &"entrance"})
	var diagnostics := {"rejected": 0}
	var count := 0
	for point in polygon:
		count += _add_component(components, corner,
			Transform3D(Basis.IDENTITY, Vector3(point.x, height * 0.5, point.y)),
			Vector3(1.0, height / corner.size.y, 1.0), footprint.id)
	for edge_index in polygon.size():
		var a := polygon[edge_index]
		var b := polygon[(edge_index + 1) % polygon.size()]
		var edge := b - a
		var length := edge.length()
		count += _add_component(components, parapet,
			_facade_transform(a, b, 0.5, height + parapet.size.y * 0.42),
			Vector3(length / parapet.size.x, 1.0, 1.0), footprint.id)
		var spacing := maxf(window.size.x * 1.75, 1.25)
		var blocked := _blocked_intervals(facade_exclusions, edge_index, length)
		for floor_index in footprint.floors:
			var intervals: Array = [[0.0, 1.0]]
			if not blocked.is_empty():
				intervals = _free_intervals(blocked, floor_index, spacing / length)
			var door_slot := {}
			if floor_index == 0 and edge_index == entrance.get("edge", -1):
				door_slot = {"interval": 0, "bay": entrance.get("bay", -1)} if blocked.is_empty() \
					else _door_slot(intervals, length, spacing)
			for slot in _facade_bays(intervals, length, spacing):
				var interval_index: int = slot["interval"]
				var bay: int = slot["bay"]
				var t: float = slot["t"]
				var slot_id := StringName("window_%d_%d_%d_%d" % [edge_index, floor_index, interval_index, bay])
				var is_door: bool = floor_index == 0 and edge_index == entrance.get("edge", -1) \
					and door_slot.get("interval", -1) == interval_index \
					and door_slot.get("bay", -1) == bay
				var definition := door if is_door else window
				var scale_factor := minf(1.0, footprint.floor_height * (0.9 if is_door else 0.62) / definition.size.y)
				var center_y := definition.size.y * scale_factor * 0.5 + 0.06 if is_door else (
					float(floor_index) * footprint.floor_height + footprint.floor_height * 0.56
				)
				var transform := _facade_transform(a, b, t, center_y)
				if is_door:
					count += _add_component(components, definition, transform,
						Vector3.ONE * scale_factor, footprint.id)
					continue
				var placed := _add_facade_component(components, definition, transform,
					Vector3.ONE * scale_factor, footprint.id, base_elevation, polygon, edge_index, t,
					obstacles, occupied, slot_id, &"", diagnostics)
				if placed == 0:
					continue
				count += placed
				if floor_index == 0:
					if random.randf() < 0.24:
						var awning_y := center_y + window.size.y * scale_factor * 0.5 + 0.22
						count += _add_decoration(components, awning, _facade_transform(a, b, t, awning_y),
							Vector3.ONE, footprint.id, base_elevation, polygon, edge_index, t, obstacles, occupied, slot_id, diagnostics)
					continue
				var choice := random.randf()
				var force_balcony: bool = edge_index == entrance.get("edge", -2) and floor_index == 1 and bay == 0
				if force_balcony or choice < 0.1:
					var balcony_y := float(floor_index) * footprint.floor_height + balcony.size.y * 0.47
					count += _add_decoration(components, balcony, _facade_transform(a, b, t, balcony_y),
						Vector3.ONE, footprint.id, base_elevation, polygon, edge_index, t, obstacles, occupied, slot_id, diagnostics)
				elif choice < 0.34:
					var drying := drying_variants[(edge_index + floor_index + bay) % drying_variants.size()]
					var drying_y := center_y - window.size.y * scale_factor * 0.25
					count += _add_decoration(components, drying, _facade_transform(a, b, t, drying_y),
						Vector3.ONE, footprint.id, base_elevation, polygon, edge_index, t, obstacles, occupied, slot_id, diagnostics)
	# 连廊门套由廊桥组件在桥端生成（见 skybridge_generator._append_portal），建筑侧只裁切门洞。
	var roof_point := _roof_anchor(polygon)
	var roof_transform := Transform3D(Basis.IDENTITY, Vector3(roof_point.x, height + roof.size.y * 0.5, roof_point.y))
	count += _add_component(components, roof, roof_transform, Vector3.ONE, footprint.id)
	occupied.append({"bounds": _component_bounds(roof, roof_transform, Vector3.ONE, base_elevation), "host_id": &"roof_hatch"})
	var drying_transform := _roof_drying_transform(polygon, roof_drying, parapet, roof_point, height, occupied, base_elevation)
	if not drying_transform.is_empty():
		count += _add_component(components, roof_drying, drying_transform["transform"], Vector3.ONE, footprint.id)
	else:
		diagnostics["rejected"] += 1
	root.set_meta("component_count", count)
	root.set_meta("triangle_count", MeshBuildUtil.triangle_count(body.mesh) + _component_triangles(components))
	# 与 PCGBuildingPlan.facade_signature_for 保持一致：增量重建的脏检查才能识别避让区变化。
	var connector_data: Array = []
	for connector in connectors:
		if connector != null:
			connector_data.append(connector.semantic_data())
	root.set_meta("semantic_digest", PCGCanonicalSerializer.hash_document({
		"building": footprint.semantic_data(),
		"terrain": [terrain.terrain_slope.x, terrain.terrain_slope.y] if terrain != null else [0.0, 0.0],
		"exclusions": facade_exclusions,
		"connectors": connector_data,
	}))
	root.set_meta("rejected_decorations", diagnostics["rejected"])
	return {"root": root, "errors": PackedStringArray()}

# 结合点在立面上占用的边内区间；exclusions 元素为 connector.exclusion() 的结果。
const DOORWAY_DEPTH := 0.45
const DOORWAY_MARGIN := 0.15

# 结合点 → 主体挤出的门洞参数（内凹洞道，裁切楼面主体）。
func _facade_openings(footprint: PCGBuildingFootprint, polygon: PackedVector2Array,
			height: float, connectors: Array) -> Array:
	var result: Array = []
	for connector in connectors:
		var opening := _connector_opening(connector, footprint, polygon, height)
		if not opening.is_empty():
			result.append(opening)
	return result

func _connector_opening(connector, footprint: PCGBuildingFootprint,
			polygon: PackedVector2Array, height: float) -> Dictionary:
	if connector == null or polygon.size() < 3:
		return {}
	var index := clampi(connector.edge_index, 0, polygon.size() - 1)
	var a: Vector2 = polygon[index]
	var b: Vector2 = polygon[(index + 1) % polygon.size()]
	var length := maxf(a.distance_to(b), 0.001)
	var y0 := clampf(float(connector.floor) * footprint.floor_height, 0.0, height)
	var y1 := clampf(y0 + float(connector.height), 0.0, height)
	var half := minf(float(connector.width) * 0.5 + DOORWAY_MARGIN, length * 0.5 - 0.05)
	if y1 - y0 < 0.3 or half <= 0.05:
		return {}
	var center := clampf(float(connector.edge_t), 0.0, 1.0) * length
	return {
		"edge_index": index,
		"s0": maxf(center - half, 0.0),
		"s1": minf(center + half, length),
		"y0": y0,
		"y1": y1,
		"depth": DOORWAY_DEPTH,
	}

func _blocked_intervals(exclusions: Array, edge_index: int, edge_length: float) -> Array:
	var cuts: Array = []
	for exclusion in exclusions:
		if exclusion.get("edge_index", -1) != edge_index:
			continue
		var t0 := clampf(float(exclusion.get("t0", 0.0)), 0.0, 1.0)
		var t1 := clampf(float(exclusion.get("t1", 0.0)), 0.0, 1.0)
		if t1 > t0:
			cuts.append({"t0": t0, "t1": t1, "floor": int(exclusion.get("floor", -1))})
	cuts.sort_custom(func(a, b): return a["t0"] < b["t0"])
	var merged: Array = []
	for cut in cuts:
		if not merged.is_empty() and cut["floor"] == merged[-1]["floor"] \
				and cut["t0"] <= merged[-1]["t1"] + 0.001:
			merged[-1]["t1"] = maxf(merged[-1]["t1"], cut["t1"])
		else:
			merged.append(cut.duplicate())
	return merged

# 某楼层上避开结合点后的自由区间；过窄的残段直接丢弃，避免碎窗。
func _free_intervals(blocked: Array, floor_index: int, min_width: float) -> Array:
	var intervals: Array = [[0.0, 1.0]]
	for cut in blocked:
		if int(cut["floor"]) != floor_index:
			continue
		var next: Array = []
		for interval in intervals:
			if cut["t1"] <= interval[0] or cut["t0"] >= interval[1]:
				next.append(interval)
				continue
			if cut["t0"] > interval[0] + min_width:
				next.append([interval[0], cut["t0"]])
			if cut["t1"] < interval[1] - min_width:
				next.append([cut["t1"], interval[1]])
		intervals = next
	return intervals

# 立面开间推导：入口选择与窗口/门排布共用同一套 bay 索引与 t 计算，
# 保证门一定落在真实开间中心，而不是另一套间距公式算出的位置。
func _facade_bays(intervals: Array, edge_length: float, spacing: float) -> Array:
	var result: Array = []
	for interval_index in intervals.size():
		var span: float = intervals[interval_index][1] - intervals[interval_index][0]
		var bays := int(floor(span * edge_length / spacing))
		for bay in bays:
			result.append({
				"interval": interval_index,
				"bay": bay,
				"t": intervals[interval_index][0] + (float(bay) + 0.5) / float(bays) * span,
			})
	return result

# 入口被结合点遮挡时，改放到含原中点的区间；否则放最大区间的中间开间。
func _door_slot(intervals: Array, edge_length: float, spacing: float) -> Dictionary:
	if intervals.is_empty():
		return {}
	var chosen := 0
	for index in intervals.size():
		if intervals[index][0] <= 0.5 and intervals[index][1] >= 0.5:
			chosen = index
			break
		if intervals[index][1] - intervals[index][0] > intervals[chosen][1] - intervals[chosen][0]:
			chosen = index
	var span: float = intervals[chosen][1] - intervals[chosen][0]
	var bays := maxi(1, int(floor(span * edge_length / spacing)))
	return {"interval": chosen, "bay": bays / 2}

func _choose_entrance(polygon: PackedVector2Array, door: PCGBuildingComponentDefinition,
			window: PCGBuildingComponentDefinition, building_id: StringName,
			obstacles: Array, base_elevation: float) -> Dictionary:
	var best: Dictionary = {}
	var best_length := 0.0
	var spacing := maxf(window.size.x * 1.75, 1.25)
	for edge_index in polygon.size():
		var a := polygon[edge_index]
		var b := polygon[(edge_index + 1) % polygon.size()]
		var length := a.distance_to(b)
		for slot in _facade_bays([[0.0, 1.0]], length, spacing):
			var t: float = slot["t"]
			var transform := _facade_transform(a, b, t, door.size.y * 0.5 + 0.06)
			var bounds := _component_bounds(door, transform, Vector3.ONE, base_elevation)
			if not _corner_clearance(polygon, edge_index, t, door):
				continue
			if _hits_obstacles(bounds, building_id, obstacles):
				continue
			if length > best_length:
				best_length = length
				best = {"edge": edge_index, "bay": slot["bay"], "bounds": bounds}
	return best

func _add_decoration(parent: Node3D, definition: PCGBuildingComponentDefinition,
			transform: Transform3D, component_scale: Vector3, building_id: StringName,
			base_elevation: float, polygon: PackedVector2Array, edge_index: int, t: float,
			obstacles: Array, occupied: Array[Dictionary], slot_id: StringName,
			diagnostics: Dictionary) -> int:
	return _add_facade_component(parent, definition, transform, component_scale, building_id,
		base_elevation, polygon, edge_index, t, obstacles, occupied, slot_id, slot_id, diagnostics)

func _add_facade_component(parent: Node3D, definition: PCGBuildingComponentDefinition,
			transform: Transform3D, component_scale: Vector3, building_id: StringName,
			base_elevation: float, polygon: PackedVector2Array, edge_index: int, t: float,
			obstacles: Array, occupied: Array[Dictionary], slot_id: StringName, host_id: StringName,
			diagnostics: Dictionary) -> int:
	if not _corner_clearance(polygon, edge_index, t, definition):
		diagnostics["rejected"] += 1
		return 0
	var bounds := _component_bounds(definition, transform, component_scale, base_elevation)
	var padded := bounds.grow(0.035)
	for record in occupied:
		if not host_id.is_empty() and record["host_id"] == host_id:
			continue
		if padded.intersects(record["bounds"]):
			diagnostics["rejected"] += 1
			return 0
	if _hits_obstacles(bounds, building_id, obstacles):
		diagnostics["rejected"] += 1
		return 0
	var placed := _add_component(parent, definition, transform, component_scale, building_id)
	if placed > 0:
		occupied.append({"bounds": bounds, "host_id": slot_id})
		parent.get_child(parent.get_child_count() - 1).set_meta("host_window_id", host_id)
		parent.get_child(parent.get_child_count() - 1).set_meta("slot_id", slot_id)
	return placed

func _corner_clearance(polygon: PackedVector2Array, edge_index: int, t: float,
			definition: PCGBuildingComponentDefinition) -> bool:
	var length := polygon[edge_index].distance_to(polygon[(edge_index + 1) % polygon.size()])
	var margin := definition.size.x * 0.5 + 0.12
	var start_margin := margin + (definition.size.z if _is_concave(polygon, edge_index) else 0.0)
	var end_margin := margin + (definition.size.z if _is_concave(polygon, (edge_index + 1) % polygon.size()) else 0.0)
	return t * length >= start_margin and (1.0 - t) * length >= end_margin

func _is_concave(polygon: PackedVector2Array, vertex: int) -> bool:
	var count := polygon.size()
	var previous := polygon[(vertex - 1 + count) % count]
	var current := polygon[vertex]
	var next := polygon[(vertex + 1) % count]
	return (current - previous).cross(next - current) < -0.0001

func _component_bounds(definition: PCGBuildingComponentDefinition,
			transform: Transform3D, component_scale: Vector3,
			base_elevation: float = 0.0) -> AABB:
	var local := definition.get_mesh().get_aabb()
	var world := Transform3D(transform.basis * Basis.from_scale(component_scale), transform.origin)
	var first := true
	var result := AABB()
	for x in [local.position.x, local.end.x]:
		for y in [local.position.y, local.end.y]:
			for z in [local.position.z, local.end.z]:
				var point := world * Vector3(x, y, z)
				if first:
					result = AABB(point, Vector3.ZERO)
					first = false
				else:
					result = result.expand(point)
	result.position.y += base_elevation
	return result

func _hits_obstacles(bounds: AABB, building_id: StringName, obstacles: Array) -> bool:
	for obstacle in obstacles:
		if obstacle == null or obstacle.id == building_id:
			continue
		if bounds.position.y > obstacle.ground_elevation + obstacle.height() or bounds.end.y < obstacle.ground_elevation:
			continue
		var rect := PackedVector2Array([
			Vector2(bounds.position.x, bounds.position.z), Vector2(bounds.end.x, bounds.position.z),
			Vector2(bounds.end.x, bounds.end.z), Vector2(bounds.position.x, bounds.end.z),
		])
		for part in Geometry2D.intersect_polygons(rect, obstacle.normalized_polygon()):
			if absf(PCGBuildingFootprint.signed_area(part)) > 0.001:
				return true
	return false

func _add_component(parent: Node3D, definition: PCGBuildingComponentDefinition,
			transform: Transform3D, component_scale: Vector3, building_id: StringName) -> int:
	var visual := MeshInstance3D.new()
	visual.name = "%s_%d" % [definition.id, parent.get_child_count()]
	visual.mesh = definition.get_mesh()
	visual.transform = Transform3D(transform.basis * Basis.from_scale(component_scale), transform.origin)
	visual.set_meta("component_id", definition.id)
	visual.set_meta("component_role", definition.role)
	visual.set_meta("building_id", building_id)
	for surface in visual.mesh.get_surface_count():
		var accent := surface == 1
		var material_id := definition.accent_material_id if accent else definition.material_id
		var color := definition.accent_color if accent else definition.color
		visual.set_surface_override_material(surface, preload("res://addons/pcg_shared/pcg_material_access.gd").library().solid(
			material_id, color, 0.24 if accent else 0.82
		))
	parent.add_child(visual)
	return 1

func _facade_transform(a: Vector2, b: Vector2, t: float, y: float) -> Transform3D:
	var edge := b - a
	var outward := Vector3(edge.y, 0.0, -edge.x).normalized()
	var right := Vector3.UP.cross(outward).normalized()
	var point := a.lerp(b, t)
	return Transform3D(Basis(right, Vector3.UP, outward), Vector3(point.x, y, point.y) + outward * 0.025)

func _base_elevation(polygon: PackedVector2Array, terrain: PCGBuildingPlan) -> float:
	if terrain == null or terrain.terrain_slope.is_zero_approx():
		return 0.0
	var highest := -INF
	for point in polygon:
		highest = maxf(highest, terrain.terrain_height_at(point))
	return highest + 0.04

func _roof_drying_transform(polygon: PackedVector2Array, definition: PCGBuildingComponentDefinition,
			parapet: PCGBuildingComponentDefinition, roof_point: Vector2, height: float,
			occupied: Array[Dictionary], base_elevation: float) -> Dictionary:
	var usable_parts := Geometry2D.offset_polygon(polygon, -(parapet.size.z * 0.5 + 0.12), Geometry2D.JOIN_MITER)
	if usable_parts.is_empty():
		return {}
	var best := Transform3D()
	var best_score := -INF
	for rotation in [0.0, PI * 0.5]:
		var basis := Basis(Vector3.UP, rotation)
		var local_bounds := _component_bounds(definition, Transform3D(basis, Vector3.ZERO), Vector3.ONE, base_elevation)
		for usable in usable_parts:
			var bounds := Rect2(usable[0], Vector2.ZERO)
			for point in usable:
				bounds = bounds.expand(point)
			var candidates: Array[Vector2] = [_roof_anchor(usable), roof_point]
			var steps := Vector2(0.45, 0.45)
			var count_x := int(ceil(bounds.size.x / steps.x))
			var count_y := int(ceil(bounds.size.y / steps.y))
			for ix in count_x + 1:
				for iy in count_y + 1:
					candidates.append(bounds.position + Vector2(minf(ix * steps.x, bounds.size.x), minf(iy * steps.y, bounds.size.y)))
			for point in candidates:
				var rect := PackedVector2Array([
					point + Vector2(local_bounds.position.x, local_bounds.position.z),
					point + Vector2(local_bounds.end.x, local_bounds.position.z),
					point + Vector2(local_bounds.end.x, local_bounds.end.z),
					point + Vector2(local_bounds.position.x, local_bounds.end.z),
				])
				if not _rect_inside_polygon(rect, usable):
					continue
				var transform := Transform3D(basis, Vector3(point.x, height + definition.size.y * 0.5 + 0.06, point.y))
				var component_bounds := _component_bounds(definition, transform, Vector3.ONE, base_elevation)
				var conflict := false
				for record in occupied:
					if component_bounds.grow(0.04).intersects(record["bounds"]):
						conflict = true
						break
				if conflict:
					continue
				var score := point.distance_squared_to(roof_point)
				if score > best_score:
					best_score = score
					best = transform
	if best_score == -INF:
		return {}
	return {"transform": best}

func _rect_inside_polygon(rect: PackedVector2Array, polygon: PackedVector2Array) -> bool:
	var rect_area := absf(PCGBuildingFootprint.signed_area(rect))
	if rect_area <= 0.001:
		return false
	var covered := 0.0
	for part in Geometry2D.intersect_polygons(rect, polygon):
		covered += absf(PCGBuildingFootprint.signed_area(part))
	return covered >= rect_area - 0.002

func _roof_anchor(polygon: PackedVector2Array) -> Vector2:
	var center := Vector2.ZERO
	for point in polygon:
		center += point
	center /= float(polygon.size())
	if Geometry2D.is_point_in_polygon(center, polygon):
		return center
	var triangles := Geometry2D.triangulate_polygon(polygon)
	if triangles.is_empty():
		return polygon[0]
	return (polygon[triangles[0]] + polygon[triangles[1]] + polygon[triangles[2]]) / 3.0

func _component_triangles(parent: Node3D) -> int:
	var count := 0
	for child in parent.get_children():
		if child is MeshInstance3D and child.mesh != null:
			count += MeshBuildUtil.triangle_count(child.mesh)
	return count
