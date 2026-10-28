extends RefCounted

var main
var failures := PackedStringArray()

func run() -> void:
	await main.get_tree().process_frame
	await main.get_tree().physics_frame
	_smoke_check(main.catalog.definitions.size() == 3, "应加载圆形、方形与拱形三份组件资产")
	main._begin_library_drag(&"round_window")
	main._update_library_drag(main._screen_for_anchor(Vector2(0.0, 0.8)))
	_smoke_check(main.ghost_valid, "库预览应命中主体")
	_smoke_check(main.wall.outline.visible, "视口交叠应高亮主体轮廓")
	main._finish_library_drag()
	_smoke_check(main.components.size() == 1, "有效松开应创建一个组件")
	_smoke_check(not main.wall.outline.visible, "拖放结束应清除高亮")
	var round_window: PCGSurfaceComponent = main.components[0]
	main._begin_library_drag(&"square_window")
	main._update_library_drag(main._screen_for_anchor(Vector2(0.0, -0.8)))
	main._finish_library_drag()
	_smoke_check(main.components.size() == 2, "第二次库拖放应创建方窗")
	var square_window: PCGSurfaceComponent = main.components[1]
	var drag_target := square_window.anchor + Vector2(0.0, 1.35)
	if DisplayServer.get_name() == "headless":
		main._move_component(round_window, drag_target)
	else:
		var drag_start: Vector2 = main._screen_for_anchor(round_window.anchor)
		var drag_end: Vector2 = main._screen_for_anchor(drag_target)
		var press := InputEventMouseButton.new()
		press.button_index = MOUSE_BUTTON_LEFT
		press.pressed = true
		press.position = drag_start
		press.global_position = drag_start
		Input.parse_input_event(press)
		await main.get_tree().process_frame
		var motion := InputEventMouseMotion.new()
		motion.position = drag_end
		motion.global_position = drag_end
		motion.relative = drag_end - drag_start
		motion.button_mask = MOUSE_BUTTON_MASK_LEFT
		Input.parse_input_event(motion)
		await main.get_tree().process_frame
		var release := InputEventMouseButton.new()
		release.button_index = MOUSE_BUTTON_LEFT
		release.pressed = false
		release.position = drag_end
		release.global_position = drag_end
		Input.parse_input_event(release)
		await main.get_tree().process_frame
		_smoke_check(round_window.anchor.distance_to(drag_target) < 0.01, "真实输入事件应拖动已放置组件")
	_smoke_check(square_window.current_scale < 1.0 and square_window.active, "重叠应使方窗缩小但保持激活")
	main._move_component(round_window, square_window.anchor + Vector2(0.0, 0.6))
	_smoke_check(not square_window.active, "低于阈值应使方窗消失")
	_smoke_check(square_window.cutter.get_parent() == null, "消失组件应移除 CSG 开洞体")
	main._select_component(round_window)
	main._move_component(round_window, Vector2(0.0, 1.5))
	_smoke_check(square_window.active and is_equal_approx(square_window.current_scale, 1.0), "移开后方窗应完整恢复")
	main._move_component(round_window, square_window.anchor + Vector2(0.0, 1.35))
	var compressed_scale := square_window.current_scale
	main._select_component(square_window)
	main._move_component(square_window, Vector2(1.8, -0.8))
	_smoke_check(is_equal_approx(square_window.current_scale, compressed_scale), "再次选中并拖动压缩组件必须保留当前尺寸")
	main._move_component(round_window, Vector2(0.0, 1.5))
	_smoke_check(is_equal_approx(square_window.current_scale, compressed_scale), "被选中的压缩组件不得因移开而自动恢复")
	main._move_component(round_window, square_window.anchor + Vector2(0.0, 0.6))
	_smoke_check(not square_window.active, "再次压缩到阈值后组件应保持消失")
	main.handle_drag = "scale"
	main.handle_start_mouse = Vector2.ZERO
	main.handle_start_scale = square_window.current_scale
	main._drag_transform_handle(Vector2(100.0, 0.0))
	_smoke_check(square_window.current_scale > 0.0 and square_window.active, "手动缩放必须能从消失状态恢复")
	main.handle_drag = ""
	square_window.user_scale = 1.0
	square_window.neighborhood_scale = 1.0
	square_window.apply_scale(1.0)
	var count: int = main.components.size()
	main._begin_library_drag(&"round_window")
	main._update_library_drag(Vector2(4.0, 4.0))
	_smoke_check(not main.ghost_valid and not main.wall.outline.visible, "空白处预览不应吸附或高亮")
	main._finish_library_drag()
	_smoke_check(main.components.size() == count, "无效松开不应创建组件")
	await main.get_tree().process_frame
	await main.get_tree().process_frame
	var fused_meshes = main.wall.combiner.get_meshes()
	_smoke_check(fused_meshes.size() == 2 and fused_meshes[1] is Mesh, "CSG 应输出实际融合网格")
	_smoke_check(main.hosts.size() == 2, "应存在平面与圆柱两个吸附主体")
	var cylinder_anchor := Vector2(0.0, 0.6)
	var cylinder_transform: Transform3D = main.cylinder_host.surface_transform(cylinder_anchor)
	var cylinder_hit: Dictionary = main.cylinder_host.ray_anchor(
		cylinder_transform.origin + cylinder_transform.basis.z * 3.0,
		-cylinder_transform.basis.z.normalized()
	)
	_smoke_check(not cylinder_hit.is_empty() and cylinder_hit["anchor"].distance_to(cylinder_anchor) < 0.01, "圆柱射线应返回正确弧长与高度")
	main._begin_library_drag(&"round_window")
	main._update_library_drag(main.camera.unproject_position(cylinder_transform.origin))
	_smoke_check(main.ghost_valid and main.ghost_host == main.cylinder_host, "库拖放应命中圆柱主体")
	_smoke_check(main.cylinder_host.outline.visible, "圆柱拖放交叠应显示轮廓")
	main._finish_library_drag()
	var cylinder_round: PCGSurfaceComponent = main.components[-1]
	_smoke_check(cylinder_round.wall == main.cylinder_host and main.cylinder_host.combiner.get_meshes().size() == 2, "圆柱应生成实际 CSG 融合网格")
	_smoke_check(cylinder_round.visuals[0].material == round_window.visuals[0].material, "相同材质 ID 的组件必须复用材质实例")
	var ring_arrays: Array = round_window.visuals[0].mesh.surface_get_arrays(0)
	var ring_uvs: PackedVector2Array = ring_arrays[Mesh.ARRAY_TEX_UV] if ring_arrays[Mesh.ARRAY_TEX_UV] != null else PackedVector2Array()
	_smoke_check(ring_uvs.size() == ring_arrays[Mesh.ARRAY_VERTEX].size(), "程序圆环应包含完整世界尺度 UV")
	var root_radius := 0.0
	var front_radius := 0.0
	var half_frame_depth: float = (cylinder_round.definition.depth + cylinder_round.definition.root_embed) * 0.5
	for vertex in ring_arrays[Mesh.ARRAY_VERTEX] as PackedVector3Array:
		if is_equal_approx(vertex.z, -half_frame_depth):
			root_radius = maxf(root_radius, Vector2(vertex.x, vertex.y).length())
		if is_equal_approx(vertex.z, half_frame_depth):
			front_radius = maxf(front_radius, Vector2(vertex.x, vertex.y).length())
	var frame_center_z: float = cylinder_round.visuals[0].get_meta("component_local").origin.z
	_smoke_check(is_equal_approx(frame_center_z - half_frame_depth, -cylinder_round.definition.root_embed), "root_embed 正值必须把根面放在局部负 Z")
	_smoke_check(is_equal_approx(frame_center_z + half_frame_depth, cylinder_round.definition.depth), "窗户外沿必须位于局部正 Z 的 depth")
	_smoke_check(root_radius > front_radius * 1.05, "梯形圆台根面必须大于外沿")
	main._select_component(cylinder_round)
	var shared_frame := cylinder_round.visuals[0].material as ShaderMaterial
	var original_frame_mesh: Mesh = cylinder_round.visuals[0].mesh
	var test_image := Image.create(2, 2, false, Image.FORMAT_RGB8)
	test_image.fill(Color("80c060"))
	var test_texture := ImageTexture.create_from_image(test_image)
	main.frame_slot_panel.profile.set_texture_for_slot(&"base_color", test_texture)
	main.frame_slot_panel.texture_changed.emit(&"base_color", test_texture)
	_smoke_check(shared_frame.get_shader_parameter("base_texture") == test_texture and shared_frame.get_shader_parameter("use_base_texture"), "填入 BaseColor 应刷新共享材质 uniform")
	_smoke_check(cylinder_round.visuals[0].material == shared_frame and cylinder_round.visuals[0].mesh == original_frame_mesh, "贴图变更不得替换材质实例或重建组件网格")
	main.frame_slot_panel._clear_slot(&"base_color")
	_smoke_check(not shared_frame.get_shader_parameter("use_base_texture") and cylinder_round.visuals[0].material == shared_frame, "清除贴图应恢复默认回退并保持共享实例")
	main._select_component(round_window)
	main._move_component(round_window, Vector2(0.0, 1.5))
	main._move_component(cylinder_round, square_window.anchor)
	_smoke_check(is_equal_approx(square_window.current_scale, 1.0) and is_equal_approx(cylinder_round.current_scale, 1.0), "不同主体的组件不应互相缩放")
	var curved_anchor := Vector2(1.0, 0.4)
	main._move_component(cylinder_round, curved_anchor)
	var angle: float = curved_anchor.x / main.cylinder_host.cylinder_radius
	var expected_normal: Vector3 = (main.cylinder_host.global_basis * Vector3(sin(angle), 0.0, cos(angle))).normalized()
	_smoke_check(cylinder_round.global_basis.z.normalized().dot(expected_normal) > 0.999, "圆柱拖动后组件应沿径向法线定向")
	main._select_component(cylinder_round)
	main._on_attachment_angle_changed(25.0)
	var tilted_normal: Vector3 = (main.cylinder_host.surface_transform(curved_anchor) * Transform3D(Basis(Vector3.RIGHT, deg_to_rad(25.0)), Vector3.ZERO)).basis.z.normalized()
	_smoke_check(cylinder_round.global_basis.z.normalized().dot(tilted_normal) > 0.999, "法线倾角应旋转完整组件")
	main._on_attachment_angle_changed(0.0)
	cylinder_round.set_user_scale(1.5)
	main._solve_neighborhood(cylinder_round)
	_smoke_check(is_equal_approx(cylinder_round.current_scale, 1.5), "用户缩放应与邻域缩放相乘")
	cylinder_round.set_user_scale(1.0)
	main._solve_neighborhood(cylinder_round)
	if DisplayServer.get_name() != "headless":
		await main.get_tree().physics_frame
		var angle_handle_position := Vector3(0.0, cylinder_round.definition.size.y * 0.5 + 0.42, 0.14)
		var angle_handle_screen: Vector2 = main.camera.unproject_position(cylinder_round.gizmo_root.to_global(angle_handle_position))
		_smoke_check(main._pick_transform_handle(angle_handle_screen) == "angle", "橙色手柄应可拾取")
		await _smoke_mouse_drag(angle_handle_screen, angle_handle_screen + Vector2(0.0, -50.0))
		_smoke_check(absf(cylinder_round.attachment_angle_degrees - 20.0) < 0.01, "角度手柄应驱动法线倾角")
		var scale_handle_position := Vector3(cylinder_round.definition.size.x * 0.5 + 0.42, 0.0, 0.14)
		var scale_handle_screen: Vector2 = main.camera.unproject_position(cylinder_round.gizmo_root.to_global(scale_handle_position))
		_smoke_check(main._pick_transform_handle(scale_handle_screen) == "scale", "绿色手柄应可拾取")
		await _smoke_mouse_drag(scale_handle_screen, scale_handle_screen + Vector2(100.0, 0.0))
		_smoke_check(absf(cylinder_round.user_scale - 1.5) < 0.01, "缩放手柄应驱动用户等比缩放")
		main._on_attachment_angle_changed(0.0)
		cylinder_round.set_user_scale(1.0)
		main._solve_neighborhood(cylinder_round)
	var equator: float = main.cylinder_host.cylinder_height * 0.5
	var dome_anchor := Vector2(0.0, equator + 0.65)
	var dome_transform: Transform3D = main.cylinder_host.surface_transform(dome_anchor)
	var dome_hit: Dictionary = main.cylinder_host.ray_anchor(
		dome_transform.origin + dome_transform.basis.z * 3.0,
		-dome_transform.basis.z.normalized()
	)
	_smoke_check(not dome_hit.is_empty() and dome_hit["anchor"].distance_to(dome_anchor) < 0.01, "半球射线应返回连续球面锚点")
	var below_equator: Transform3D = main.cylinder_host.surface_transform(Vector2(0.0, equator - 0.001))
	var above_equator: Transform3D = main.cylinder_host.surface_transform(Vector2(0.0, equator + 0.001))
	_smoke_check(below_equator.origin.distance_to(above_equator.origin) < 0.01 and below_equator.basis.z.dot(above_equator.basis.z) > 0.999, "圆柱与半球在赤道处应连续")
	main._move_component(cylinder_round, dome_anchor)
	_smoke_check(cylinder_round.global_basis.z.normalized().dot(dome_transform.basis.z.normalized()) > 0.999, "组件在半球上应遵循球面法线")
	_smoke_check(main.cylinder_host.base_shapes.size() == 2 and main.cylinder_host.outline_parts.size() == 2, "组合主体应包含圆柱、半球实体与轮廓")
	_smoke_check(cylinder_round.transition_shape != null and cylinder_round.effective_transition_thickness() > 0.0, "曲面组件应生成自适应包裹过渡")
	_smoke_check(_mesh_is_closed(cylinder_round.transition_shape.mesh), "包裹过渡应为封闭水密 Mesh")
	var transition_arrays := cylinder_round.transition_shape.mesh.surface_get_arrays(0)
	_smoke_check(transition_arrays[Mesh.ARRAY_NORMAL][0].z > 0.0, "过渡顶面法线必须朝向正 Z 外侧")
	var has_outward_transition := false
	for vertex in transition_arrays[Mesh.ARRAY_VERTEX] as PackedVector3Array:
		if vertex.z > 0.01:
			has_outward_transition = true
	_smoke_check(has_outward_transition, "包裹过渡必须露出主体正 Z 外侧，不能全部埋入根部")
	cylinder_round.set_transition_enabled(false)
	_smoke_check(cylinder_round.transition_shape == null, "关闭过渡应移除对应 CSG")
	cylinder_round.set_transition_enabled(true)
	_smoke_check(cylinder_round.transition_shape != null and cylinder_round.transition_shape.get_parent() == main.cylinder_host.combiner, "重新开启应恢复过渡 CSG")
	var cached_transition_mesh := cylinder_round.transition_mesh_cache
	cylinder_round.update_transform()
	_smoke_check(cylinder_round.transition_mesh_cache == cached_transition_mesh, "参数未变化时必须复用过渡 Mesh")
	cylinder_round.set_transition_deferred(true)
	cylinder_round.transition_thickness = 0.8
	cylinder_round.update_transform()
	_smoke_check(cylinder_round.transition_shape.mesh == cached_transition_mesh and cylinder_round.transition_render.mesh != cached_transition_mesh, "拖动中应只更新直接预览并延迟凹形 CSG")
	cylinder_round.flush_transition_csg()
	_smoke_check(cylinder_round.transition_shape.mesh == cylinder_round.transition_mesh_cache, "交互结束必须提交最新过渡 CSG")
	cylinder_round.transition_thickness = 1.0
	cylinder_round.transition_curvature = 1.0
	cylinder_round.update_transform()
	_smoke_check(is_equal_approx(cylinder_round.effective_transition_thickness(), 1.0), "显式厚度应覆盖自适应默认值")
	transition_arrays = cylinder_round.transition_shape.mesh.surface_get_arrays(0)
	var max_transition_height := -INF
	for vertex in transition_arrays[Mesh.ARRAY_VERTEX] as PackedVector3Array:
		max_transition_height = maxf(max_transition_height, vertex.z)
	_smoke_check(max_transition_height > 0.2, "最大厚度与弧度必须形成有高度的圆弧截面")
	cylinder_round.transition_curvature = -1.0
	cylinder_round.update_transform()
	_smoke_check(_mesh_is_closed(cylinder_round.transition_shape.mesh), "负弧度过渡必须保持封闭")
	transition_arrays = cylinder_round.transition_shape.mesh.surface_get_arrays(0)
	max_transition_height = -INF
	for vertex in transition_arrays[Mesh.ARRAY_VERTEX] as PackedVector3Array:
		max_transition_height = maxf(max_transition_height, vertex.z)
	_smoke_check(max_transition_height > 0.2, "弧度 -1 必须形成完整反向圆弧")
	var arch_window: PCGSurfaceComponent = main._place_component(&"arch_window", Vector2(1.5, 0.0), main.wall)
	_smoke_check(arch_window.definition.shape == PCGComponentDefinition.Shape.ARCH_WINDOW, "拱形资产应按通用轮廓类型创建")
	_smoke_check(_mesh_is_closed(arch_window.cutter.mesh), "拱形开洞体必须封闭")
	_smoke_check(_mesh_signed_volume(arch_window.cutter.mesh) < 0.0, "拱形开洞体必须使用朝外法线")
	_smoke_check(_mesh_is_closed(arch_window.transition_shape.mesh), "拱形根部过渡必须封闭")
	transition_arrays = arch_window.transition_shape.mesh.surface_get_arrays(0)
	var upward_normal_count := 0
	for normal in transition_arrays[Mesh.ARRAY_NORMAL] as PackedVector3Array:
		if normal.z > 0.1:
			upward_normal_count += 1
	_smoke_check(upward_normal_count > transition_arrays[Mesh.ARRAY_NORMAL].size() / 4, "过渡顶面法线必须朝向主体外侧")
	var arch_full_vertices: int = arch_window.transition_shape.mesh.surface_get_arrays(0)[Mesh.ARRAY_VERTEX].size()
	arch_window.transition_density = 0.25
	arch_window.update_transform()
	var arch_low_vertices: int = arch_window.transition_shape.mesh.surface_get_arrays(0)[Mesh.ARRAY_VERTEX].size()
	_smoke_check(arch_low_vertices < arch_full_vertices, "25% 精度必须减少过渡顶点")
	arch_window.transition_density = 2.0
	arch_window.update_transform()
	var arch_high_vertices: int = arch_window.transition_shape.mesh.surface_get_arrays(0)[Mesh.ARRAY_VERTEX].size()
	_smoke_check(arch_high_vertices > arch_full_vertices, "200% 精度必须增加过渡顶点")
	arch_window.transition_lod = 2
	arch_window.update_transform()
	var arch_lod_vertices: int = arch_window.transition_shape.mesh.surface_get_arrays(0)[Mesh.ARRAY_VERTEX].size()
	_smoke_check(arch_lod_vertices < arch_high_vertices, "LOD 2 必须降低过渡顶点数")
	arch_window.transition_density = 1.0
	main._update_inspector()
	_smoke_check(main.transition_density_option.selected == 2 and main.transition_density_option.get_item_text(2) == "100%", "密度 1.0 必须默认显示 100%")
	var before_preview_transform: Transform3D = arch_window.visuals[0].global_transform
	main._on_deferred_fusion_toggled(true)
	arch_window.anchor.x += 0.2
	arch_window.update_transform()
	_smoke_check(arch_window.visuals[0].global_transform == before_preview_transform and arch_window.direct_root.visible, "后合并预览不得更新 CSG 变换")
	main._merge_selected()
	_smoke_check(not arch_window.direct_root.visible and arch_window.visuals[0].global_transform != before_preview_transform, "合并选中必须提交最新组件状态")
	main._merge_all()
	_smoke_check(not main.wall.preview_mode and not main.cylinder_host.preview_mode, "全部合并必须退出预览模式")
	await main.get_tree().process_frame
	await main.get_tree().process_frame
	cylinder_round.transition_thickness = -1.0
	cylinder_round.transition_curvature = 0.65
	cylinder_round.update_transform()
	await main.get_tree().process_frame
	await main.get_tree().process_frame
	for host in main.hosts:
		_smoke_check(not host.render_meshes.is_empty(), "最终平滑渲染 Chunk 应已生成")
		var source_vertex_count := 0
		for surface in host.solid_mesh.get_surface_count():
			source_vertex_count += host.solid_mesh.surface_get_arrays(surface)[Mesh.ARRAY_VERTEX].size()
		var baked_vertex_count := 0
		for chunk_instance in host.render_meshes:
			_smoke_check(chunk_instance.mesh != null and chunk_instance.mesh.get_surface_count() > 0, "渲染单元应包含有效 Surface")
			if chunk_instance.mesh == null:
				continue
			for surface in chunk_instance.mesh.get_surface_count():
				baked_vertex_count += chunk_instance.mesh.surface_get_arrays(surface)[Mesh.ARRAY_VERTEX].size()
			var arrays: Array = chunk_instance.mesh.surface_get_arrays(0)
			var normals: PackedVector3Array = arrays[Mesh.ARRAY_NORMAL] if arrays[Mesh.ARRAY_NORMAL] != null else PackedVector3Array()
			var uvs: PackedVector2Array = arrays[Mesh.ARRAY_TEX_UV] if arrays[Mesh.ARRAY_TEX_UV] != null else PackedVector2Array()
			_smoke_check(normals.size() == arrays[Mesh.ARRAY_VERTEX].size() and uvs.size() == normals.size(), "Chunk 应保留完整法线和 UV0")
			for normal in normals:
				_smoke_check(absf(normal.length() - 1.0) <= 0.001, "Chunk 法线应保持单位长度")
			_smoke_check(MaterialLibrary.batch_key(chunk_instance.mesh.surface_get_material(0)) != &"unassigned", "Chunk 应具有稳定材质分组键")
		_smoke_check(baked_vertex_count >= source_vertex_count, "同材质多 Surface 合批不得丢失源顶点")
	main._toggle_wireframe(true)
	var wireframe_valid := true
	for host in main.hosts:
		for chunk_instance in host.render_meshes:
			wireframe_valid = wireframe_valid and chunk_instance.material_override == host.wireframe_material
	_smoke_check(wireframe_valid, "线框开关应作用于全部 Chunk")
	main._toggle_wireframe(false)
	var solid_valid := true
	for host in main.hosts:
		for chunk_instance in host.render_meshes:
			solid_valid = solid_valid and chunk_instance.material_override == null
	_smoke_check(solid_valid, "关闭线框应恢复全部 Chunk 的表面材质")
	for i in 6:
		await main.get_tree().process_frame
	if failures.is_empty():
		print("PCG_SMOKE_TEST_PASS: dual hosts, smoothed CSG render, visible wireframe material, snapping, handles, isolated shrink")
		main.get_tree().quit(0)
	else:
		for failure in failures:
			push_error("SMOKE: " + failure)
		main.get_tree().quit(1)

func _smoke_mouse_drag(start: Vector2, finish: Vector2) -> void:
	var press := InputEventMouseButton.new()
	press.button_index = MOUSE_BUTTON_LEFT
	press.pressed = true
	press.position = start
	press.global_position = start
	Input.parse_input_event(press)
	await main.get_tree().process_frame
	var motion := InputEventMouseMotion.new()
	motion.position = finish
	motion.global_position = finish
	motion.relative = finish - start
	motion.button_mask = MOUSE_BUTTON_MASK_LEFT
	Input.parse_input_event(motion)
	await main.get_tree().process_frame
	var release := InputEventMouseButton.new()
	release.button_index = MOUSE_BUTTON_LEFT
	release.pressed = false
	release.position = finish
	release.global_position = finish
	Input.parse_input_event(release)
	await main.get_tree().process_frame

func _mesh_is_closed(mesh: Mesh) -> bool:
	if mesh == null:
		return false
	var edges: Dictionary = {}
	for surface in mesh.get_surface_count():
		var arrays := mesh.surface_get_arrays(surface)
		var vertices: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
		var indices: PackedInt32Array = arrays[Mesh.ARRAY_INDEX] if arrays[Mesh.ARRAY_INDEX] != null else PackedInt32Array()
		if indices.is_empty():
			for i in vertices.size():
				indices.append(i)
		for i in range(0, indices.size(), 3):
			for corner in 3:
				var a := str(vertices[indices[i + corner]])
				var b := str(vertices[indices[i + (corner + 1) % 3]])
				var key := a + "|" + b if a < b else b + "|" + a
				edges[key] = int(edges.get(key, 0)) + 1
	for count in edges.values():
		if count != 2:
			return false
	return not edges.is_empty()

func _mesh_signed_volume(mesh: Mesh) -> float:
	var volume := 0.0
	for surface in mesh.get_surface_count():
		var arrays := mesh.surface_get_arrays(surface)
		var vertices: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
		var indices: PackedInt32Array = arrays[Mesh.ARRAY_INDEX] if arrays[Mesh.ARRAY_INDEX] != null else PackedInt32Array()
		if indices.is_empty():
			for i in vertices.size():
				indices.append(i)
		for i in range(0, indices.size(), 3):
			volume += vertices[indices[i]].dot(vertices[indices[i + 1]].cross(vertices[indices[i + 2]])) / 6.0
	return volume

func _smoke_check(condition: bool, message: String) -> void:
	if not condition:
		failures.append(message)
