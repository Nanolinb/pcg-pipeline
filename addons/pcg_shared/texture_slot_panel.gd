class_name PCGTextureSlotPanel
extends VBoxContainer

signal texture_changed(slot: StringName, texture: Texture2D)
signal load_failed(message: String)

const SLOT_LABELS := {
	&"base_color": "BaseColor",
	&"detail": "Detail",
	&"normal": "Normal",
	&"orm": "ORM",
}

var profile: PCGMaterialProfile
var heading: String = ""
var _buttons: Dictionary = {}
var _clear_buttons: Dictionary = {}
var _dialog: FileDialog
var _active_slot: StringName = &""

func _ready() -> void:
	add_theme_constant_override("separation", 5)
	if not heading.is_empty():
		var title := Label.new()
		title.text = heading
		add_child(title)
	for slot in PCGMaterialProfile.SLOT_IDS:
		var row := HBoxContainer.new()
		row.add_theme_constant_override("separation", 5)
		add_child(row)
		var label := Label.new()
		label.text = SLOT_LABELS[slot]
		label.custom_minimum_size.x = 76.0
		row.add_child(label)
		var button := Button.new()
		button.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		button.tooltip_text = "浏览并填入贴图；默认表示使用自动回退纹理"
		button.pressed.connect(_browse.bind(slot))
		row.add_child(button)
		_buttons[slot] = button
		var clear := Button.new()
		clear.text = "×"
		clear.tooltip_text = "清空自定义贴图并恢复默认"
		clear.pressed.connect(_clear_slot.bind(slot))
		row.add_child(clear)
		_clear_buttons[slot] = clear
	_dialog = FileDialog.new()
	_dialog.file_mode = FileDialog.FILE_MODE_OPEN_FILE
	_dialog.access = FileDialog.ACCESS_FILESYSTEM
	_dialog.filters = PackedStringArray(["*.png,*.jpg,*.jpeg,*.webp,*.bmp,*.tga ; 图片贴图"])
	_dialog.file_selected.connect(_on_file_selected)
	add_child(_dialog)
	refresh()

func set_profile(value: PCGMaterialProfile) -> void:
	profile = value
	refresh()

func refresh() -> void:
	if profile == null:
		return
	for slot in PCGMaterialProfile.SLOT_IDS:
		if not _buttons.has(slot):
			continue
		var texture := profile.texture_for_slot(slot)
		var button: Button = _buttons[slot]
		button.text = "默认" if texture == null else (texture.resource_path.get_file() if not texture.resource_path.is_empty() else "已自定义")
		_clear_buttons[slot].disabled = texture == null

func _browse(slot: StringName) -> void:
	_active_slot = slot
	_dialog.popup_centered(Vector2i(820, 560))

func _clear_slot(slot: StringName) -> void:
	profile.set_texture_for_slot(slot, null)
	refresh()
	texture_changed.emit(slot, null)

func _on_file_selected(path: String) -> void:
	var image := Image.load_from_file(path)
	if image == null or image.is_empty():
		load_failed.emit("无法读取贴图：" + path)
		return
	var texture := ImageTexture.create_from_image(image)
	profile.set_texture_for_slot(_active_slot, texture)
	refresh()
	texture_changed.emit(_active_slot, texture)
