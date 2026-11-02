@tool
class_name PCGSurfacePreview
extends RefCounted

# v0.16 L1 标准资产试装：把一份已发布（或待发布）资产真实摆到宿主表面锚点。
#
# build_surface_preview(asset, host, anchor) -> MeshInstance3D：
# - 变换：宿主表面标架 × 资产轴对齐 × 根部偏移/嵌入。锚点处表面点即资产根点，
#   根点沿表面内法向嵌入 root_embed 米（与任务/资产约定一致）。
# - 网格：默认 LOD0，options.lod = 1/2 用对应 LOD，options.whitebox = true
#   用白盒（AABB 盒网格，发布时随资产持久化）。
# - 碰撞：按资产 collision_policy 输出真实碰撞体（box=包围盒、convex=网格
#   顶点凸包、concave=逐三角形面片、none=不挂碰撞），挂在 StaticBody3D 子节点。
# - 碰撞层语义（位掩码常量）：试装产出的结构体固定在 HOST 层、只掩 PLAYER；
#   EMBEDDED/EXCLUSION/PROXY 供占用区域代理体使用，PICKABLE 供拾取代理使用。
# 纯静态工厂：不依赖场景树，headless 可完整验证。

## 默认碰撞层/掩码（位值）。输出结构体：layer=HOST，mask=PLAYER。
const COLLISION_LAYER_HOST := 1
const COLLISION_LAYER_PICKABLE := 2
const COLLISION_LAYER_PLAYER := 4
const COLLISION_LAYER_EMBEDDED := 8
const COLLISION_LAYER_EXCLUSION := 16
const COLLISION_LAYER_PROXY := 32

## options 键：lod(int 0..2)、whitebox(bool)、collision(bool，默认 true)。
static func build_surface_preview(asset: PCGStandardAsset, host: PCGSurfaceHost,
		anchor: Vector2, options: Dictionary = {}) -> MeshInstance3D:
	if asset == null:
		push_error("PCGSurfacePreview.build_surface_preview: asset is null")
		return null
	if host == null:
		push_error("PCGSurfacePreview.build_surface_preview: host is null")
		return null
	var frame := host.surface_transform(anchor)
	var basis := _aligned_basis(asset, frame.basis)
	var origin := frame.origin + basis * asset.root_offset \
		- frame.basis.z.normalized() * asset.root_embed

	var preview := MeshInstance3D.new()
	preview.name = StringName("preview_" + String(asset.asset_id()))
	if options.get("whitebox", false):
		preview.mesh = asset.whitebox_mesh if asset.whitebox_mesh != null \
			else make_whitebox_mesh(asset.mesh_aabb())
	else:
		var lod := int(options.get("lod", 0))
		preview.mesh = _mesh_for_lod(asset, lod)
	preview.transform = Transform3D(basis, origin)
	if options.get("collision", true):
		var body := build_collision_body(asset)
		if body != null:
			preview.add_child(body)
			body.owner = preview
	return preview


## 按碰撞策略构建 StaticBody3D（含 CollisionShape3D）；none 返回 null。
## 层语义：结构体固定在 HOST 层、只与 PLAYER 碰撞。
static func build_collision_body(asset: PCGStandardAsset) -> StaticBody3D:
	var shape := build_collision_shape(asset)
	if shape == null:
		return null
	var body := StaticBody3D.new()
	body.name = "collision"
	body.collision_layer = COLLISION_LAYER_HOST
	body.collision_mask = COLLISION_LAYER_PLAYER
	var collision_shape := CollisionShape3D.new()
	collision_shape.shape = shape
	var aabb := asset.mesh_aabb()
	if asset.collision_policy == &"box":
		collision_shape.transform = Transform3D(Basis.IDENTITY, aabb.get_center())
	body.add_child(collision_shape)
	collision_shape.owner = body
	return body


## 按碰撞策略构建 Shape3D（box/convex/concave/none -> null）。
static func build_collision_shape(asset: PCGStandardAsset) -> Shape3D:
	var aabb := asset.mesh_aabb()
	match asset.collision_policy:
		&"box":
			var box := BoxShape3D.new()
			box.size = aabb.size
			return box
		&"convex":
			var hull := ConvexPolygonShape3D.new()
			hull.points = _mesh_vertex_positions(asset.normalized_mesh)
			return hull
		&"concave":
			var faces := ConcavePolygonShape3D.new()
			faces.set_faces(_mesh_triangle_positions(asset.normalized_mesh))
			return faces
	return null


## 白盒网格：资产 AABB 的 12 三角盒网格（资产局部坐标）。
static func make_whitebox_mesh(aabb: AABB) -> ArrayMesh:
	var p := {
		"000": aabb.position,
		"001": aabb.position + Vector3(0, 0, aabb.size.z),
		"010": aabb.position + Vector3(0, aabb.size.y, 0),
		"011": aabb.position + Vector3(0, aabb.size.y, aabb.size.z),
		"100": aabb.position + Vector3(aabb.size.x, 0, 0),
		"101": aabb.position + Vector3(aabb.size.x, 0, aabb.size.z),
		"110": aabb.position + Vector3(aabb.size.x, aabb.size.y, 0),
		"111": aabb.position + aabb.size,
	}
	var quads: Array = [
		["010", "110", "111", "011"],
		["000", "001", "101", "100"],
		["000", "100", "110", "010"],
		["001", "101", "111", "011"],
		["000", "010", "011", "001"],
		["100", "101", "111", "110"],
	]
	var surface_tool := SurfaceTool.new()
	surface_tool.begin(Mesh.PRIMITIVE_TRIANGLES)
	for quad in quads:
		surface_tool.add_vertex(p[quad[0]])
		surface_tool.add_vertex(p[quad[1]])
		surface_tool.add_vertex(p[quad[2]])
		surface_tool.add_vertex(p[quad[0]])
		surface_tool.add_vertex(p[quad[2]])
		surface_tool.add_vertex(p[quad[3]])
	surface_tool.index()
	surface_tool.generate_normals()
	return surface_tool.commit()


static func _mesh_for_lod(asset: PCGStandardAsset, lod: int) -> ArrayMesh:
	match lod:
		1:
			return asset.lod1_mesh if asset.lod1_mesh != null else asset.normalized_mesh
		2:
			return asset.lod2_mesh if asset.lod2_mesh != null else asset.normalized_mesh
	return asset.normalized_mesh


## 资产局部轴 → 宿主表面标架 的旋转对齐（默认轴时退化为表面标架）。
static func _aligned_basis(asset: PCGStandardAsset, frame_basis: Basis) -> Basis:
	var asset_z := asset.outward_axis.normalized()
	var asset_x := asset.up_axis.cross(asset_z).normalized()
	var asset_y := asset_z.cross(asset_x).normalized()
	var asset_basis := Basis(asset_x, asset_y, asset_z).orthonormalized()
	var target := frame_basis.orthonormalized()
	return (target * asset_basis.inverse()).orthonormalized()


static func _mesh_vertex_positions(mesh: ArrayMesh) -> PackedVector3Array:
	var positions := PackedVector3Array()
	if mesh == null:
		return positions
	for surface_index in mesh.get_surface_count():
		positions.append_array(mesh.surface_get_arrays(surface_index)[Mesh.ARRAY_VERTEX])
	return positions


static func _mesh_triangle_positions(mesh: ArrayMesh) -> PackedVector3Array:
	var positions := PackedVector3Array()
	if mesh == null:
		return positions
	for surface_index in mesh.get_surface_count():
		var arrays := mesh.surface_get_arrays(surface_index)
		var indices: PackedInt32Array = arrays[Mesh.ARRAY_INDEX]
		var verts: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
		for index in indices:
			positions.append(verts[index])
	return positions
