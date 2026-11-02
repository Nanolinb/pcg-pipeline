class_name PipePreset
extends Resource

@export var id: StringName
@export var display_name: String
@export_multiline var description: String
@export var diameter: float = 0.34
@export var diameter_profile: Array = []
@export var radial_segments: int = 24
@export var texture_world_size: float = 0.65
@export var default_corner_segments: int = 8
@export var auto_optimize: bool = true
@export var texture_link: bool = true
@export var straight_step: float = 4.0
@export var curve_step: float = 0.28
@export var straight_angle: float = 3.0
@export var manual_step: float = 0.18
@export var detail_tiling: float = 6.0
@export var detail_strength: float = 0.28
@export var normal_strength: float = 0.55
@export var ao_strength: float = 0.0
@export var tint: Color = Color.WHITE
@export var metallic_offset: float = 0.0
@export var roughness_offset: float = 0.0
