@tool
class_name PCGSkybridgeGenerator
extends RefCounted

# 廊桥网络生成器：解析结合点 → 生成/编辑路径 → 交叉分析（合并或错开）→ 扫掠封闭截面 Mesh。
# 横截面高度重叠超过 60% 的交叉廊桥合并为一个 cross 交叉结构；
# 否则通过 auto_lift 垂直错开，错开量保留在生成数据中并可继续手动微调。

const Connector = preload("res://scripts/building/skybridge_connector.gd")
const Bridge = preload("res://scripts/building/skybridge_definition.gd")
const Component = preload("res://scripts/building/building_component_definition.gd")
const MeshFactory = preload("res://scripts/building/building_mesh_factory.gd")

const MERGE_OVERLAP := 0.6
const CLEARANCE := 0.6
const SAMPLES_PER_SPAN := 8
# 与 building_generator.DOORWAY_DEPTH 一致：桥端伸入内凹门洞，顶住洞道背板。
const RECESS_DEPTH := 0.45

# 依据两个结合点创建默认廊桥（直线路径，中间一个可编辑节点）。
# 截面尺寸与材质取自廊桥标准组件（component_id）；起止楼层不同即自动生成坡道。
func make_bridge(plan: PCGBuildingPlan, first: PCGSkybridgeConnector,
			second: PCGSkybridgeConnector, bridge_id: StringName,
			catalog: PCGBuildingComponentCatalog = null) -> Dictionary:
	if first == null or second == null:
		return {"bridge": null, "errors": PackedStringArray(["结合点不存在。"])}
	var errors := first.validation_errors(plan.get_footprint(first.building_id))
	errors.append_array(second.validation_errors(plan.get_footprint(second.building_id)))
	if not errors.is_empty():
		return {"bridge": null, "errors": errors}
	var anchor_a: Dictionary = first.anchor(plan.get_footprint(first.building_id))
	var anchor_b: Dictionary = second.anchor(plan.get_footprint(second.building_id))
	var pa: Vector3 = anchor_a["position"] - anchor_a["outward"] * RECESS_DEPTH
	var pb: Vector3 = anchor_b["position"] - anchor_b["outward"] * RECESS_DEPTH
	var bridge := Bridge.new()
	bridge.id = bridge_id
	bridge.connector_a = first.id
	bridge.connector_b = second.id
	bridge.width = maxf(first.width, 1.0)
	bridge.height = maxf(first.height, 2.0)
	var component := bridge_component(bridge, catalog)
	bridge.width = component.size.x
	bridge.height = component.size.y
	# 配色与两端建筑保持一致：取两栋墙色的中间色，顶棚/立柱/扶手由生成器派生同色系深浅。
	var footprint_a := plan.get_footprint(first.building_id)
	var footprint_b := plan.get_footprint(second.building_id)
	if footprint_a != null and footprint_b != null:
		bridge.color = footprint_a.wall_color.lerp(footprint_b.wall_color, 0.5)
	else:
		bridge.color = component.color
	bridge.nodes = [
		{"position": pa, "tension": 1.0},
		{"position": (pa + pb) * 0.5, "tension": 1.0},
		{"position": pb, "tension": 1.0},
	]
	return {"bridge": bridge, "errors": PackedStringArray()}

# 廊桥使用的标准组件；未提供目录或找不到组件时回退到桥定义自带的尺寸。
func bridge_component(bridge: PCGSkybridgeDefinition,
			catalog: PCGBuildingComponentCatalog) -> PCGBuildingComponentDefinition:
	if catalog != null:
		var component: PCGBuildingComponentDefinition = catalog.get_definition(bridge.component_id)
		if component != null:
			return component
	var fallback := Component.new()
	fallback.size = Vector3(bridge.width, bridge.height, 1.0)
	return fallback

func build_network(plan: PCGBuildingPlan,
			catalog: PCGBuildingComponentCatalog = null) -> Dictionary:
	var errors := PackedStringArray()
	for connector in plan.connectors:
		if connector == null:
			errors.append("平面包含空结合点。")
			continue
		var footprint := plan.get_footprint(connector.building_id)
		var issues := connector.validation_errors(footprint)
		for issue in issues:
			errors.append("%s：%s" % [connector.id, issue])
	var active: Array[PCGSkybridgeDefinition] = []
	for bridge in plan.skybridges:
		if bridge == null:
			errors.append("平面包含空廊桥。")
			continue
		for issue in bridge.validation_errors():
			errors.append("%s：%s" % [bridge.id, issue])
		if not plan.get_connector(bridge.connector_a) or not plan.get_connector(bridge.connector_b):
			errors.append("廊桥 %s 引用了不存在的结合点。" % bridge.id)
		else:
			active.append(bridge)
	if not errors.is_empty():
		return {"root": null, "errors": errors, "junctions": [], "lifted": [], "merged": []}

	var junctions: Array = []
	var lifted := PackedStringArray()
	var merged := PackedStringArray()
	var junction_mesh_parts: Array = []
	for i in active.size():
		for j in range(i + 1, active.size()):
			var first := active[i]
			var second := active[j]
			if first.connector_a == second.connector_a or first.connector_b == second.connector_b \
					or first.connector_a == second.connector_b or first.connector_b == second.connector_a:
				continue
			var conflict := _cross_conflict(first, second)
			if conflict.is_empty():
				continue
			if float(conflict["overlap_ratio"]) > MERGE_OVERLAP:
				junctions.append(conflict)
				merged.append_array([String(first.id), String(second.id)])
				junction_mesh_parts.append_array(_junction_parts(conflict))
			else:
				_lift_pair(first, second, conflict)
				lifted.append(String(second.id) if String(second.id) > String(first.id) else String(first.id))

	var root := Node3D.new()
	root.name = "Skybridges"
	var triangle_count := 0
	for bridge in active:
		var component := bridge_component(bridge, catalog)
		var built := _bridge_mesh(bridge, component)
		var mesh: ArrayMesh = built["mesh"]
		var visual := MeshInstance3D.new()
		visual.name = "Skybridge_%s" % bridge.id
		visual.mesh = mesh
		visual.set_meta("bridge_id", bridge.id)
		visual.set_meta("bridge_role", "skybridge")
		visual.set_meta("component_id", component.id)
		visual.set_meta("component_count", 1)
		visual.set_meta("post_count", built["post_count"])
		visual.set_meta("baluster_count", built["baluster_count"])
		for surface in mesh.get_surface_count():
			var material_id := component.material_id
			var surface_color := bridge.color.darkened(0.05)
			var roughness := 0.6
			match surface:
				1:
					material_id = component.accent_material_id
					surface_color = bridge.color.lightened(0.2)
					roughness = 0.5
				2:
					surface_color = bridge.color.darkened(0.28)
			visual.set_surface_override_material(surface, _material_library().solid(
				material_id, surface_color, roughness))
		root.add_child(visual)
		triangle_count += _triangle_count(mesh)
	var junction_index := 0
	for part in junction_mesh_parts:
		var box := MeshInstance3D.new()
		box.name = "SkybridgeJunction_%d" % junction_index
		box.mesh = _boxes([part])
		box.material_override = _material_library().solid(&"building/skybridge_junction", Color("5d7f8c"), 0.4)
		box.set_meta("bridge_role", "skybridge_junction")
		box.set_meta("junction_index", junction_index)
		root.add_child(box)
		triangle_count += _triangle_count(box.mesh)
		junction_index += 1
	root.set_meta("junctions", junctions)
	root.set_meta("lifted", lifted)
	root.set_meta("merged", merged)
	root.set_meta("component_count", active.size() + junction_mesh_parts.size())
	root.set_meta("triangle_count", triangle_count)
	root.set_meta("semantic_digest", PCGCanonicalSerializer.hash_document(network_semantic_data(plan)))
	return {
		"root": root,
		"errors": PackedStringArray(),
		"junctions": junctions,
		"lifted": lifted,
		"merged": merged,
	}

func network_semantic_data(plan: PCGBuildingPlan) -> Dictionary:
	var connectors: Array = []
	for connector in plan.connectors:
		if connector != null:
			connectors.append(connector.semantic_data())
	var bridges: Array = []
	for bridge in plan.skybridges:
		if bridge != null:
			bridges.append(bridge.semantic_data())
	return {"connectors": connectors, "skybridges": bridges}

# 最近平面距离小于半宽和时返回冲突数据，否则返回空字典。
func _cross_conflict(first: PCGSkybridgeDefinition, second: PCGSkybridgeDefinition) -> Dictionary:
	var path_a := first.sampled_path(SAMPLES_PER_SPAN)
	var path_b := second.sampled_path(SAMPLES_PER_SPAN)
	var best := INF
	var best_a := Vector3.ZERO
	var best_b := Vector3.ZERO
	for pa in path_a:
		for pb in path_b:
			var distance := Vector2(pa.x, pa.z).distance_to(Vector2(pb.x, pb.z))
			if distance < best:
				best = distance
				best_a = pa
				best_b = pb
	if best >= (first.width + second.width) * 0.5:
		return {}
	var bottom := maxf(best_a.y, best_b.y)
	var top := minf(best_a.y + first.height, best_b.y + second.height)
	var vertical_overlap := top - bottom
	var ratio := vertical_overlap / minf(first.height, second.height)
	var midpoint := (best_a + best_b) * 0.5
	var dir_a := _path_direction_at(path_a, best_a)
	var dir_b := _path_direction_at(path_b, best_b)
	var deck_y := minf(best_a.y, best_b.y)
	return {
		"position": midpoint,
		"deck_y": deck_y,
		"height": maxf(best_a.y + first.height, best_b.y + second.height) - deck_y,
		"overlap_ratio": ratio,
		"dir_a": dir_a,
		"dir_b": dir_b,
		"width_a": first.width,
		"width_b": second.width,
	}

# ID 较大的一座垂直抬升到另一座上方，保留 CLEARANCE 净空。
func _lift_pair(first: PCGSkybridgeDefinition, second: PCGSkybridgeDefinition,
			conflict: Dictionary) -> void:
	var lower := second
	var upper := first
	if String(second.id) > String(first.id):
		lower = first
		upper = second
	var path_l := lower.sampled_path(SAMPLES_PER_SPAN)
	var path_u := upper.sampled_path(SAMPLES_PER_SPAN)
	var top_l := -INF
	for point in path_l:
		top_l = maxf(top_l, point.y + lower.height)
	var deck_u := INF
	for point in path_u:
		deck_u = minf(deck_u, point.y)
	var target := top_l + CLEARANCE
	if deck_u < target:
		upper.auto_lift += target - deck_u

# 合并的 cross 结构：沿两个桥向各放一个交汇盒，合并渲染为一个结构。
func _junction_parts(conflict: Dictionary) -> Array:
	var position: Vector3 = conflict["position"]
	var deck_y: float = conflict["deck_y"]
	var junction_height: float = conflict["height"]
	var size_a: Vector3 = Vector3(conflict["width_a"] + 0.6, junction_height, conflict["width_b"] + 0.6)
	var size_b: Vector3 = Vector3(conflict["width_b"] + 0.6, junction_height, conflict["width_a"] + 0.6)
	var basis_a := Basis.looking_at(Vector3(conflict["dir_a"].x, 0.0, conflict["dir_a"].z), Vector3.UP)
	var basis_b := Basis.looking_at(Vector3(conflict["dir_b"].x, 0.0, conflict["dir_b"].z), Vector3.UP)
	var center := position + Vector3(0.0, junction_height * 0.5, 0.0)
	return [
		{"size": size_a, "center": center, "basis": basis_a},
		{"size": size_b, "center": center, "basis": basis_b},
	]

func _path_direction_at(path: PackedVector3Array, near: Vector3) -> Vector3:
	var best_index := 0
	var best := INF
	for index in path.size():
		if path[index].distance_squared_to(near) < best:
			best = path[index].distance_squared_to(near)
			best_index = index
	var a := path[max(best_index - 1, 0)]
	var b := path[min(best_index + 1, path.size() - 1)]
	var direction := b - a
	direction.y = 0.0
	return direction.normalized() if direction.length() > 0.001 else Vector3.FORWARD

# 沿采样路径扫掠标准组件横截面（薄桥面、扶手横档、出挑顶棚），
# 支撑顶棚的立柱按桥长等距独立放置，侧面保持镂空；坡道/弧度自动跟随路径切向。
func _bridge_mesh(bridge: PCGSkybridgeDefinition,
			component: PCGBuildingComponentDefinition) -> Dictionary:
	var groups := MeshFactory.skybridge_part_groups(component)
	var path := bridge.sampled_path(SAMPLES_PER_SPAN)
	var frame := _swept_arrays(path, groups["frame"])
	var post_count := _append_interval_posts(path, groups["post"], frame)
	var mesh := _mesh(frame[0], frame[1], frame[2], frame[3])
	var accent := _swept_arrays(path, groups["accent"])
	var baluster_count := _append_interval_balusters(path, groups["baluster"], accent)
	var accent_mesh := _mesh(accent[0], accent[1], accent[2], accent[3])
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, accent_mesh.surface_get_arrays(0))
	var roof := _swept_arrays(path, groups["roof"])
	var roof_mesh := _mesh(roof[0], roof[1], roof[2], roof[3])
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, roof_mesh.surface_get_arrays(0))
	return {"mesh": mesh, "post_count": post_count, "baluster_count": baluster_count}

func _path_length(path: PackedVector3Array) -> float:
	var total := 0.0
	for index in range(1, path.size()):
		total += path[index].distance_to(path[index - 1])
	return total

# 在路径上按弧长等距放置立柱，两端必有一根，数量随桥长增加。
func _append_interval_posts(path: PackedVector3Array, post_info: Dictionary,
			arrays: Array) -> int:
	var total := _path_length(path)
	var spacing: float = post_info["spacing"]
	var count := clampi(int(round(total / spacing)) + 1, 2, 64)
	var size: Vector3 = post_info["size"]
	var center_y: float = post_info["center_y"]
	for k in count:
		var sample := _sample_at_distance(path, total * float(k) / float(count - 1))
		_append_oriented_box(arrays, sample["right"], sample["up"], sample["forward"],
			sample["position"] + sample["up"] * center_y, size)
	return count

# 两侧栏杆立柱按弧长等距布置，间距由组件 baluster.spacing 决定，随桥长自动加密。
func _append_interval_balusters(path: PackedVector3Array, info: Dictionary,
			arrays: Array) -> int:
	var total := _path_length(path)
	var spacing: float = info["spacing"]
	var per_edge := clampi(int(round(total / spacing)) + 1, 2, 128)
	var size: Vector3 = info["size"]
	var center_y: float = info["center_y"]
	var lateral: float = info["x"]
	for edge_sign in [-1.0, 1.0]:
		for k in per_edge:
			var sample := _sample_at_distance(path, total * float(k) / float(per_edge - 1))
			_append_oriented_box(arrays, sample["right"], sample["up"], sample["forward"],
				sample["position"] + sample["right"] * lateral * edge_sign + sample["up"] * center_y,
				size)
	return per_edge * 2

# 按弧长在路径上取样（线性插值），返回位置与局部坐标架。
func _sample_at_distance(path: PackedVector3Array, distance: float) -> Dictionary:
	var travelled := 0.0
	for index in range(1, path.size()):
		var segment := path[index].distance_to(path[index - 1])
		if travelled + segment >= distance or index == path.size() - 1:
			var u := 0.0 if segment <= 0.0001 else clampf((distance - travelled) / segment, 0.0, 1.0)
			var position := path[index - 1].lerp(path[index], u)
			var forward := path[index] - path[index - 1]
			if forward.length() < 0.0001:
				forward = Vector3.FORWARD
			forward = forward.normalized()
			var right := Vector3.UP.cross(forward).normalized()
			return {
				"position": position,
				"forward": forward,
				"right": right,
				"up": forward.cross(right).normalized(),
			}
		travelled += segment
	return {"position": path[0], "forward": Vector3.FORWARD,
		"right": Vector3.RIGHT, "up": Vector3.UP}

# 向扫掠数组追加一个按路径坐标架定向的封闭盒（立柱）。
func _append_oriented_box(arrays: Array, right: Vector3, up: Vector3, forward: Vector3,
			center: Vector3, size: Vector3) -> void:
	var vertices: PackedVector3Array = arrays[0]
	var normals: PackedVector3Array = arrays[1]
	var uvs: PackedVector2Array = arrays[2]
	var indices: PackedInt32Array = arrays[3]
	var hx := size.x * 0.5
	var hy := size.y * 0.5
	var hz := size.z * 0.5
	var ld := center - right * hx - up * hy
	var rd := center + right * hx - up * hy
	var ru := center + right * hx + up * hy
	var lu := center - right * hx + up * hy
	var ld_b := ld - forward * hz
	var rd_b := rd - forward * hz
	var ru_b := ru - forward * hz
	var lu_b := lu - forward * hz
	var ld_f := ld + forward * hz
	var rd_f := rd + forward * hz
	var ru_f := ru + forward * hz
	var lu_f := lu + forward * hz
	_add_quad(vertices, normals, uvs, indices,
		[ld_b, ld_f, rd_f, rd_b],
		[Vector2(0, 0), Vector2(hz * 2, 0), Vector2(hz * 2, size.x), Vector2(0, size.x)])
	_add_quad(vertices, normals, uvs, indices,
		[lu_b, ru_b, ru_f, lu_f],
		[Vector2(0, 0), Vector2(0, size.x), Vector2(hz * 2, size.x), Vector2(hz * 2, 0)])
	_add_quad(vertices, normals, uvs, indices,
		[ld_b, lu_b, lu_f, ld_f],
		[Vector2(0, 0), Vector2(0, size.y), Vector2(hz * 2, size.y), Vector2(hz * 2, 0)])
	_add_quad(vertices, normals, uvs, indices,
		[rd_f, ru_f, ru_b, rd_b],
		[Vector2(hz * 2, 0), Vector2(hz * 2, size.y), Vector2(0, size.y), Vector2(0, 0)])
	_add_quad(vertices, normals, uvs, indices,
		[ld_b, rd_b, ru_b, lu_b],
		[Vector2(0, 0), Vector2(size.x, 0), Vector2(size.x, size.y), Vector2(0, size.y)])
	_add_quad(vertices, normals, uvs, indices,
		[ld_f, lu_f, ru_f, rd_f],
		[Vector2(size.x, 0), Vector2(size.x, size.y), Vector2(0, size.y), Vector2(0, 0)])

func _swept_arrays(path: PackedVector3Array, parts: Array) -> Array:
	var vertices := PackedVector3Array()
	var normals := PackedVector3Array()
	var uvs := PackedVector2Array()
	var indices := PackedInt32Array()
	var distances: Array[float] = [0.0]
	for index in range(1, path.size()):
		distances.append(distances[index - 1] + path[index].distance_to(path[index - 1]))
	var rights := PackedVector3Array()
	var ups := PackedVector3Array()
	for index in path.size():
		var forward := _frame_forward(path, index)
		var right := Vector3.UP.cross(forward).normalized()
		rights.append(right)
		ups.append(forward.cross(right).normalized())
	for part in parts:
		_sweep_part(path, part, distances, rights, ups, vertices, normals, uvs, indices)
	return [vertices, normals, uvs, indices]

func _sweep_part(path: PackedVector3Array, part: Dictionary, distances: Array[float],
			rights: PackedVector3Array, ups: PackedVector3Array,
			vertices: PackedVector3Array, normals: PackedVector3Array,
			uvs: PackedVector2Array, indices: PackedInt32Array) -> void:
	var half := Vector2(part["size"].x, part["size"].y) * 0.5
	var origin := Vector2(part["center"].x, part["center"].y)
	var rings: Array = []
	for index in path.size():
		var center: Vector3 = path[index]
		var corners := PackedVector3Array()
		for offset in [Vector2(-1, -1), Vector2(1, -1), Vector2(1, 1), Vector2(-1, 1)]:
			var lateral := origin + Vector2(offset.x * half.x, offset.y * half.y)
			corners.append(center + rights[index] * lateral.x + ups[index] * lateral.y)
		rings.append({"ld": corners[0], "rd": corners[1], "ru": corners[2], "lu": corners[3]})
	var width: float = part["size"].x
	var height: float = part["size"].y
	for index in path.size() - 1:
		var a: Dictionary = rings[index]
		var b: Dictionary = rings[index + 1]
		var u0: float = distances[index]
		var u1: float = distances[index + 1]
		_add_quad(vertices, normals, uvs, indices,
			[a["ld"], b["ld"], b["rd"], a["rd"]],
			[Vector2(u0, 0.0), Vector2(u1, 0.0), Vector2(u1, width), Vector2(u0, width)])
		_add_quad(vertices, normals, uvs, indices,
			[a["lu"], a["ru"], b["ru"], b["lu"]],
			[Vector2(u0, 0.0), Vector2(u0, width), Vector2(u1, width), Vector2(u1, 0.0)])
		_add_quad(vertices, normals, uvs, indices,
			[a["ld"], a["lu"], b["lu"], b["ld"]],
			[Vector2(u0, 0.0), Vector2(u0, height), Vector2(u1, height), Vector2(u1, 0.0)])
		_add_quad(vertices, normals, uvs, indices,
			[b["rd"], b["ru"], a["ru"], a["rd"]],
			[Vector2(u1, 0.0), Vector2(u1, height), Vector2(u0, height), Vector2(u0, 0.0)])
	var first_ring: Dictionary = rings[0]
	var last_ring: Dictionary = rings[rings.size() - 1]
	var total: float = distances[distances.size() - 1]
	_add_quad(vertices, normals, uvs, indices,
		[first_ring["ld"], first_ring["rd"], first_ring["ru"], first_ring["lu"]],
		[Vector2(0.0, 0.0), Vector2(width, 0.0), Vector2(width, height), Vector2(0.0, height)])
	_add_quad(vertices, normals, uvs, indices,
		[last_ring["ld"], last_ring["lu"], last_ring["ru"], last_ring["rd"]],
		[Vector2(total, 0.0), Vector2(total, height), Vector2(0.0, height), Vector2(0.0, 0.0)])

func _frame_forward(path: PackedVector3Array, index: int) -> Vector3:
	var a := path[max(index - 1, 0)]
	var b := path[min(index + 1, path.size() - 1)]
	var forward := b - a
	if forward.length() < 0.0001:
		return Vector3.FORWARD
	return forward.normalized()

func _add_quad(vertices: PackedVector3Array, normals: PackedVector3Array,
			uvs: PackedVector2Array, indices: PackedInt32Array,
			points: Array, quad_uvs: Array) -> void:
	var normal: Vector3 = (points[1] - points[0]).cross(points[3] - points[0]).normalized()
	for corner in [0, 1, 2, 0, 2, 3]:
		indices.append(vertices.size())
		vertices.append(points[corner])
		normals.append(normal)
		uvs.append(quad_uvs[corner])

func _boxes(parts: Array) -> ArrayMesh:
	var surface := SurfaceTool.new()
	surface.begin(Mesh.PRIMITIVE_TRIANGLES)
	for part in parts:
		var box := BoxMesh.new()
		box.size = part["size"]
		var basis: Basis = part.get("basis", Basis.IDENTITY)
		surface.append_from(box, 0, Transform3D(basis, part["center"]))
	return surface.commit()

func _mesh(vertices: PackedVector3Array, normals: PackedVector3Array,
			uvs: PackedVector2Array, indices: PackedInt32Array) -> ArrayMesh:
	var arrays: Array = []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = vertices
	arrays[Mesh.ARRAY_NORMAL] = normals
	arrays[Mesh.ARRAY_TEX_UV] = uvs
	arrays[Mesh.ARRAY_INDEX] = indices
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	return mesh

func _triangle_count(mesh: Mesh) -> int:
	var count := 0
	for surface in mesh.get_surface_count():
		var indices = mesh.surface_get_arrays(surface)[Mesh.ARRAY_INDEX]
		count += int(indices.size() / 3) if indices != null else 0
	return count

func _material_library() -> Node:
	return Engine.get_main_loop().root.get_node("MaterialLibrary")
