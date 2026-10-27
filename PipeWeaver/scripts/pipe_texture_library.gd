class_name PipeTextureLibrary
extends RefCounted

const SIZE: int = 256
static var _base: ImageTexture
static var _detail: ImageTexture
static var _normal: ImageTexture
static var _orm: ImageTexture

static func base_color() -> ImageTexture:
	if _base == null:
		_base = _make_texture("base")
	return _base

static func detail_color() -> ImageTexture:
	if _detail == null:
		_detail = _make_texture("detail")
	return _detail

static func detail_normal() -> ImageTexture:
	if _normal == null:
		_normal = _make_texture("normal")
	return _normal

static func orm() -> ImageTexture:
	if _orm == null:
		_orm = _make_texture("orm")
	return _orm

static func bake_ao(points: Array, connector_positions: Array) -> ImageTexture:
	var width: int = 64
	var height: int = 128
	var image := Image.create(width, height, false, Image.FORMAT_RGB8)
	var distances: Array[float] = [0.0]
	for i in range(1, points.size()):
		distances.append(distances[-1] + points[i - 1].distance_to(points[i]))
	var total: float = maxf(distances[-1], 0.001)
	for y in height:
		var ratio: float = float(y) / float(height - 1)
		var center: Vector3 = _sample_path(points, distances, total * ratio)
		var occlusion: float = 1.0
		for connector in connector_positions:
			var distance: float = center.distance_to(connector)
			occlusion = minf(occlusion, 0.55 + 0.45 * clampf(distance / 0.55, 0.0, 1.0))
		var contact: float = 0.96 + 0.04 * sin(ratio * TAU * 3.0)
		occlusion *= contact
		for x in width:
			var seam_relief: float = 0.985 + 0.015 * cos(float(x) / float(width) * TAU)
			image.set_pixel(x, y, Color(occlusion * seam_relief, occlusion * seam_relief, occlusion * seam_relief))
	return ImageTexture.create_from_image(image)

static func _sample_path(points: Array, distances: Array, target: float) -> Vector3:
	for i in range(1, points.size()):
		if distances[i] >= target:
			var segment: float = maxf(distances[i] - distances[i - 1], 0.0001)
			return points[i - 1].lerp(points[i], (target - distances[i - 1]) / segment)
	return points[-1]

static func _make_texture(kind: String) -> ImageTexture:
	var image := Image.create(SIZE, SIZE, false, Image.FORMAT_RGB8)
	for y in SIZE:
		for x in SIZE:
			var u: float = float(x) / SIZE
			var v: float = float(y) / SIZE
			var broad: float = sin(u * TAU * 3.0) * cos(v * TAU * 2.0)
			var fine: float = sin(u * TAU * 31.0) * sin(v * TAU * 27.0)
			var color := Color.WHITE
			match kind:
				"base":
					var variation: float = 0.92 + 0.08 * broad + 0.025 * fine
					var rust: float = maxf(0.0, sin(u * TAU * 7.0 + v * TAU * 5.0) - 0.82) * 1.8
					color = Color(0.20 * variation + rust * 0.18, 0.46 * variation + rust * 0.05, 0.52 * variation - rust * 0.04)
				"detail":
					var scratch: float = pow(absf(sin(u * TAU * 41.0 + v * TAU * 13.0)), 24.0)
					var value: float = 0.82 + broad * 0.07 + fine * 0.035 + scratch * 0.18
					color = Color(value, value, value)
				"normal":
					var nx: float = 0.10 * cos(u * TAU * 19.0) * sin(v * TAU * 17.0)
					var ny: float = 0.08 * sin(u * TAU * 23.0) * cos(v * TAU * 29.0)
					var nz: float = sqrt(maxf(0.01, 1.0 - nx * nx - ny * ny))
					color = Color(nx * 0.5 + 0.5, ny * 0.5 + 0.5, nz * 0.5 + 0.5)
				"orm":
					color = Color(0.92 + broad * 0.03, 0.40 + broad * 0.06 + fine * 0.035, 0.62, 1.0)
			image.set_pixel(x, y, color)
	return ImageTexture.create_from_image(image)
