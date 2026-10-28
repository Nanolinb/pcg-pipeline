class_name PCGMaterialProfile
extends Resource

const SLOT_IDS: Array[StringName] = [&"base_color", &"detail", &"normal", &"orm"]

@export var tint: Color = Color.WHITE
@export var base_color_texture: Texture2D
@export var detail_texture: Texture2D
@export var normal_texture: Texture2D
@export var orm_texture: Texture2D
@export_range(0.0, 1.0, 0.01) var roughness: float = 0.5
@export_range(0.0, 1.0, 0.01) var metallic: float = 0.0
@export_range(1.0, 16.0, 0.5) var detail_tiling: float = 6.0
@export_range(0.0, 1.0, 0.02) var detail_strength: float = 0.28
@export_range(0.0, 1.5, 0.05) var normal_strength: float = 0.55

func texture_for_slot(slot: StringName) -> Texture2D:
	match slot:
		&"base_color":
			return base_color_texture
		&"detail":
			return detail_texture
		&"normal":
			return normal_texture
		&"orm":
			return orm_texture
	return null

func set_texture_for_slot(slot: StringName, texture: Texture2D) -> void:
	match slot:
		&"base_color":
			base_color_texture = texture
		&"detail":
			detail_texture = texture
		&"normal":
			normal_texture = texture
		&"orm":
			orm_texture = texture
