extends Node

# BASE-03：PipeWeaver 最小 headless 自动回归（G1_Pipe 基线）。
# 覆盖：表面路径求解、管体网格生成、接头、内存 pipe_records 重编辑、Chunk 合批。
# 运行：/Applications/Godot.app/Contents/MacOS/Godot --headless --path PipeWeaver res://tests/pipeweaver_smoke.tscn
# 失败时进程以非零退出码结束，并逐条打印 PIPE_SMOKE_FAIL。

const MainScript := preload("res://scripts/main.gd")
const PipeBuilder := preload("res://addons/pcg_shared/pipe_mesh_builder.gd")
const SurfaceSolver := preload("res://addons/pcg_shared/surface_path_solver.gd")

const BASELINE_LENGTH := 3.775
const BASELINE_VERTICES := 625
const BASELINE_CONNECTORS := 4

var checks_run: int = 0
var failures: Array[String] = []

func _ready() -> void:
	print("PIPE_SMOKE_BEGIN")
	var main: Node3D = MainScript.new()
	add_child(main)
	await get_tree().process_frame
	await get_tree().physics_frame
	if main.pipe_root.get_child_count() == 0:
		# 物理空间未就绪时兜底重试一次，避免时序假阴性。
		await get_tree().physics_frame
		main._create_demo_pipe()
	_check_demo_pipe(main)
	_check_path_solver(main)
	_check_builder_direct()
	_check_multi_surface_batch()
	await _check_records_reedit_and_bake(main)
	if failures.is_empty():
		print("PIPE_SMOKE_PASS checks=%d" % checks_run)
		get_tree().quit(0)
	else:
		for failure in failures:
			printerr("PIPE_SMOKE_FAIL: %s" % failure)
		print("PIPE_SMOKE_FAIL count=%d checks=%d" % [failures.size(), checks_run])
		get_tree().quit(1)

func _check(condition: bool, label: String) -> void:
	checks_run += 1
	if condition:
		print("  ok - %s" % label)
	else:
		failures.append(label)
		printerr("  FAIL - %s" % label)

func _mesh_vertex_count(mesh: Mesh) -> int:
	var total: int = 0
	for surface in mesh.get_surface_count():
		var arrays: Array = mesh.surface_get_arrays(surface)
		total += (arrays[Mesh.ARRAY_VERTEX] as PackedVector3Array).size()
	return total

func _count_named_children(node: Node3D, prefix: String) -> int:
	var count: int = 0
	for child in node.get_children():
		if String(child.name).begins_with(prefix):
			count += 1
	return count

func _check_demo_pipe(main: Node3D) -> void:
	print("[1] 启动示例管道（G1_Pipe 基线）")
	var pipe_root: Node3D = main.pipe_root
	_check(pipe_root.get_child_count() > 0, "示例管道在 headless 下实际生成")
	_check(absf(main.generated_length - BASELINE_LENGTH) <= 0.01, "基线长度 %.3f（实测 %.3f）" % [BASELINE_LENGTH, main.generated_length])
	_check(main.generated_vertex_count == BASELINE_VERTICES, "基线顶点数 %d（实测 %d）" % [BASELINE_VERTICES, main.generated_vertex_count])
	var body: MeshInstance3D = pipe_root.get_node_or_null("ContinuousPipe") as MeshInstance3D
	_check(body != null and body.mesh != null and body.mesh.get_surface_count() == 1, "管体 ContinuousPipe 网格存在")
	if body != null and body.mesh != null:
		var arrays: Array = body.mesh.surface_get_arrays(0)
		_check((arrays[Mesh.ARRAY_INDEX] as PackedInt32Array).size() % 3 == 0, "管体索引为完整三角形")
		_check((arrays[Mesh.ARRAY_NORMAL] as PackedVector3Array).size() == (arrays[Mesh.ARRAY_VERTEX] as PackedVector3Array).size(), "管体法线与顶点一一对应")
		_check((arrays[Mesh.ARRAY_TEX_UV] as PackedVector2Array).size() == (arrays[Mesh.ARRAY_VERTEX] as PackedVector3Array).size(), "管体 UV 与顶点一一对应")
	var connector_meshes: int = 0
	for child in pipe_root.get_children():
		if child is MeshInstance3D and String(child.name) != "ContinuousPipe":
			connector_meshes += 1
	_check(connector_meshes == BASELINE_CONNECTORS, "管体附带 %d 个接头网格实例" % BASELINE_CONNECTORS)
	_check(main.generated_connector_positions.size() == BASELINE_CONNECTORS, "记录 %d 个接头位置（2 端部 + 2 变径法兰）" % BASELINE_CONNECTORS)
	_check(_count_named_children(pipe_root, "PipePickBody") == 1, "管体带拾取碰撞体")

func _check_path_solver(main: Node3D) -> void:
	print("[2] 表面路径求解（同主体 + 跨主体）")
	var box: StaticBody3D = main.main_box
	var same: Dictionary = SurfaceSolver.find_path({
		"position": Vector3(-1.8, 0.5, 1.2),
		"normal": Vector3.BACK,
		"collider": box,
	}, {
		"position": Vector3(1.8, 3.5, 1.2),
		"normal": Vector3.BACK,
		"collider": box,
	})
	_check(not same.has("error") and same["points"].size() >= 3, "同主体表面寻路返回路径点")
	var side: StaticBody3D = main.get_node("SideBlock") as StaticBody3D
	_check(side != null, "SideBlock 主体存在")
	if side == null:
		return
	var across: Dictionary = SurfaceSolver.find_path({
		"position": Vector3(-2.7, 1.9, 1.9),
		"normal": Vector3.BACK,
		"collider": side,
	}, {
		"position": Vector3(-1.0, 1.2, 1.2),
		"normal": Vector3.BACK,
		"collider": box,
	})
	_check(not across.has("error") and across["points"].size() >= 4, "跨主体最短贴合路径返回路径点")
	if not across.has("error"):
		var has_hard_corner: bool = false
		for flag in across.get("hard_corners", []):
			has_hard_corner = has_hard_corner or bool(flag)
		_check(has_hard_corner, "跨主体路径标注硬转角")

func _check_builder_direct() -> void:
	print("[3] 管体/接头构建器直测")
	var points: Array[Vector3] = [Vector3(0.0, 1.0, 0.0), Vector3(1.0, 1.0, 0.0), Vector3(2.0, 1.0, 0.0)]
	var normals: Array[Vector3] = [Vector3.UP, Vector3.UP, Vector3.UP]
	var single: Array = [{"end": 1.0, "diameter": 0.3}]
	var built: Dictionary = PipeBuilder.build(points, normals, single, 12, 0.5, 0.02, [], {})
	_check(not built.has("error"), "单段直管生成成功")
	if built.has("error"):
		return
	_check(built["mesh"] is ArrayMesh and built["mesh"].get_surface_count() == 1, "单段直管网格存在")
	_check(built["vertex_count"] == 3 * 13, "直管顶点数符合环向分段（实测 %d）" % built["vertex_count"])
	_check(built["connectors"].size() == 2, "单段管两个端部接头")
	_check(built["length"] > 1.9, "直管长度接近路径长度（实测 %.3f）" % built["length"])
	var two_segments: Array = [{"end": 0.5, "diameter": 0.3}, {"end": 1.0, "diameter": 0.5}]
	var varied: Dictionary = PipeBuilder.build(points, normals, two_segments, 12, 0.5, 0.02, [], {})
	_check(not varied.has("error") and varied["connectors"].size() == 3, "两段变径产生 3 个接头")
	if varied.has("error"):
		return
	var coupling: ArrayMesh = PipeBuilder.connector_mesh(built["connectors"][0], 12, 0.5)
	_check(coupling.get_surface_count() >= 1 and _mesh_vertex_count(coupling) > 0, "接头网格可构建且非空")

func _check_multi_surface_batch() -> void:
	print("[4] 同材质多 Surface 合批")
	var mesh := ArrayMesh.new()
	var material := StandardMaterial3D.new()
	for surface_index in 2:
		var arrays: Array = []
		arrays.resize(Mesh.ARRAY_MAX)
		var offset := float(surface_index) * 2.0
		arrays[Mesh.ARRAY_VERTEX] = PackedVector3Array([
			Vector3(offset, 0.0, 0.0),
			Vector3(offset + 1.0, 0.0, 0.0),
			Vector3(offset, 1.0, 0.0),
		])
		arrays[Mesh.ARRAY_NORMAL] = PackedVector3Array([Vector3.BACK, Vector3.BACK, Vector3.BACK])
		arrays[Mesh.ARRAY_TEX_UV] = PackedVector2Array([Vector2.ZERO, Vector2.RIGHT, Vector2.UP])
		arrays[Mesh.ARRAY_INDEX] = PackedInt32Array([0, 1, 2])
		mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
		mesh.surface_set_material(surface_index, material)
	var baker := PCGMeshChunkBaker.new(8.0)
	baker.append(mesh)
	var chunks: Array[Dictionary] = baker.build()
	_check(chunks.size() == 1, "同材质同区域 Surface 合并为一个 Chunk")
	if chunks.is_empty():
		return
	var vertices: PackedVector3Array = chunks[0]["mesh"].surface_get_arrays(0)[Mesh.ARRAY_VERTEX]
	_check(vertices.size() == 6, "不同 Surface 的相同旧索引不复用顶点（实测 %d）" % vertices.size())
	_check(vertices.has(Vector3(2.0, 0.0, 0.0)) and vertices.has(Vector3(3.0, 0.0, 0.0)), "第二 Surface 顶点位置未串用第一 Surface")

func _check_records_reedit_and_bake(main: Node3D) -> void:
	print("[5] 内存 pipe_records 重编辑与 Chunk 合批")
	# 完成管 1，新建管 2 并提交另一条路径。
	main._finish_current_pipe()
	_check(main.pipe_records.has(1) and main.pipe_records[1]["finalized"], "管 1 完成并写入 pipe_records")
	var solved: Dictionary = SurfaceSolver.find_path({
		"position": Vector3(-1.8, 0.4, 1.2),
		"normal": Vector3.BACK,
		"collider": main.main_box,
	}, {
		"position": Vector3(1.8, 3.6, 1.2),
		"normal": Vector3.BACK,
		"collider": main.main_box,
	})
	_check(not solved.has("error"), "管 2 路径求解成功")
	if solved.has("error"):
		return
	main._new_pipe()
	main.segments = [{"end": 1.0, "diameter": 0.2}]
	main._commit_path(solved["points"], solved["normals"], main.main_box, "smoke pipe 2")
	_check(main.current_pipe_id == 2 and main.generated_vertex_count > 0, "管 2 已生成（顶点 %d）" % main.generated_vertex_count)
	var pipe2_vertices: int = main.generated_vertex_count
	main._finish_current_pipe()
	_check(main.pipe_records.has(2), "管 2 完成并写入 pipe_records")
	# 重编辑管 1：内存记录应恢复控制点并复用原 root 重新生成。
	var pipe1_root: Node3D = main.pipe_records[1]["root"]
	main.selected_pipe_ids.assign([1])
	main._reedit_selected_pipe()
	_check(main.current_pipe_id == 1, "重编辑后当前管道切回管 1")
	_check(main.pipe_root == pipe1_root, "重编辑复用原 pipe root")
	_check(main.control_points.size() == main.pipe_records[1]["points"].size() and main.control_points.size() >= 2, "控制点从内存记录恢复")
	_check(main.generated_vertex_count == BASELINE_VERTICES, "重编辑后重新生成基线网格（顶点 %d）" % main.generated_vertex_count)
	# 再次完成管 1 并塌陷为 Chunk 合批网格。先记录源网格三角形索引总数，
	# 合批后按索引守恒校验（chunk 边界会复制顶点，顶点数不守恒属预期）。
	var source_index_total: int = 0
	for child in pipe1_root.get_children():
		if child is MeshInstance3D and child.mesh != null:
			for surface in child.mesh.get_surface_count():
				var source_arrays: Array = child.mesh.surface_get_arrays(surface)
				var source_indices: PackedInt32Array = source_arrays[Mesh.ARRAY_INDEX]
				if not source_indices.is_empty():
					source_index_total += source_indices.size()
				else:
					source_index_total += (source_arrays[Mesh.ARRAY_VERTEX] as PackedVector3Array).size()
	main._finish_current_pipe()
	main.selected_pipe_ids.assign([1])
	main._collapse_selected_pipes()
	var record1: Dictionary = main.pipe_records[1]
	_check(record1["baked"], "管 1 标记为已合批")
	_check(record1["points"].size() >= 2, "合批后 PCG 记录仍保留（可恢复编辑）")
	var fixed_root: Node3D = record1["root"]
	_check(fixed_root != null and String(fixed_root.name) == "Pipe_001_Fixed", "合批根节点命名为 Pipe_001_Fixed")
	if fixed_root == null:
		return
	var chunk_count: int = int(fixed_root.get_meta("chunk_count", 0))
	_check(chunk_count >= 1, "Chunk 数量 >= 1（实测 %d）" % chunk_count)
	var chunk_mesh_nodes: int = 0
	var chunk_index_total: int = 0
	var body_vertices: int = 0
	for child in fixed_root.get_children():
		if not child is MeshInstance3D:
			continue
		chunk_mesh_nodes += 1
		var mesh: ArrayMesh = child.mesh as ArrayMesh
		_check(mesh != null and mesh.get_surface_count() == 1, "Chunk %s 网格有效" % child.name)
		if mesh == null:
			continue
		var arrays: Array = mesh.surface_get_arrays(0)
		_check((arrays[Mesh.ARRAY_VERTEX] as PackedVector3Array).size() >= 3, "Chunk %s 顶点非空" % child.name)
		_check((arrays[Mesh.ARRAY_INDEX] as PackedInt32Array).size() % 3 == 0, "Chunk %s 索引为完整三角形" % child.name)
		chunk_index_total += (arrays[Mesh.ARRAY_INDEX] as PackedInt32Array).size()
		var library: Node = get_tree().root.get_node("MaterialLibrary")
		if library.batch_key(mesh.surface_get_material(0)) == &"pipe/body":
			body_vertices += _mesh_vertex_count(mesh)
	_check(chunk_mesh_nodes == chunk_count, "Chunk 网格节点数与 meta 一致（%d == %d）" % [chunk_mesh_nodes, chunk_count])
	_check(chunk_index_total == source_index_total, "合批三角形索引守恒（源 %d -> 合批 %d）" % [source_index_total, chunk_index_total])
	_check(body_vertices >= BASELINE_VERTICES, "合批管体顶点含源网格（%d >= %d，差额为 chunk 边界复制）" % [body_vertices, BASELINE_VERTICES])
	_check(_count_named_children(fixed_root, "PipePickBody") >= 1, "合批根保留拾取碰撞体")
	# 合批后再重编辑管 2，验证内存记录仍可恢复并重新生成。
	main.selected_pipe_ids.assign([2])
	main._reedit_selected_pipe()
	_check(main.current_pipe_id == 2, "合批后重编辑切回管 2")
	_check(main.pipe_records[2]["baked"] == false, "重编辑清除管 2 baked 标记")
	_check(main.generated_vertex_count == pipe2_vertices, "管 2 从记录恢复并重新生成（顶点 %d）" % main.generated_vertex_count)
	_check(main.pipe_root.get_node_or_null("ContinuousPipe") != null, "管 2 root 下重新生成 ContinuousPipe")
