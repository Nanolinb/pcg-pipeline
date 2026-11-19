extends SceneTree

const CAPTURE_DIR := "res://reports/release_verification/v0.16.3"

var failures := PackedStringArray()
var checks := 0

func _initialize() -> void:
	call_deferred("_run")

func _run() -> void:
	if DisplayServer.get_name() == "headless":
		print("WALL_PANEL_GRAPHICAL_RESULT: FAIL requires a graphical renderer")
		quit(1)
		return
	root.size = Vector2i(1440, 900)
	var scene: PackedScene = load("res://scenes/building_workbench.tscn")
	var workbench := scene.instantiate()
	root.add_child(workbench)
	await process_frame
	await physics_frame
	await process_frame
	workbench._select_footprint(&"house_l")
	var house: PCGBuildingFootprint = workbench.plan.get_footprint(&"house_l")
	var untouched: Node3D = workbench.building_nodes[&"house_tower"]
	var original_count := int(workbench.building_nodes[&"house_l"].get_meta("wall_panel_count", 0))

	await _click(workbench.panel_preview_check)
	_check(not house.wall_panels_fused, "真实点击应开启墙板单元预览")
	_check(workbench.building_nodes[&"house_l"].get_node_or_null("WallPanels") != null,
		"真实点击后应显示 WallPanels")
	_check(workbench.building_nodes[&"house_tower"] == untouched,
		"真实点击不得重建另一栋建筑")
	await _capture("wall_panel_preview")

	await _click(workbench.panel_width_spin.get_line_edit())
	workbench.panel_width_spin.get_line_edit().grab_focus()
	workbench.panel_width_spin.get_line_edit().select_all()
	await _type_text("2.50")
	await _key(KEY_ENTER)
	_check(is_equal_approx(house.wall_panel_width, 2.5), "真实文本输入应把墙板模数改为 2.5 m")
	_check(int(workbench.building_nodes[&"house_l"].get_meta("wall_panel_count", 0)) != original_count,
		"真实模数输入应更新派生墙板布局")

	await _click(workbench.fuse_panels_button)
	_check(house.wall_panels_fused, "真实点击确认按钮应融合整栋墙板")
	_check(workbench.building_nodes[&"house_l"].get_node_or_null("DerivedSolid") != null,
		"确认融合后应恢复 DerivedSolid")
	_check(workbench.building_nodes[&"house_tower"] == untouched,
		"确认融合不得重建另一栋建筑")
	await _capture("wall_panel_fused")

	await _key(KEY_Z, true)
	_check(not house.wall_panels_fused, "真实撤销快捷键应恢复单元预览")
	_check(is_equal_approx(house.wall_panel_width, 2.5), "撤销融合不应回退此前的模数编辑")

	workbench.queue_free()
	await process_frame
	await process_frame
	if failures.is_empty():
		print("WALL_PANEL_GRAPHICAL_RESULT: PASS checks=%d" % checks)
		quit(0)
	else:
		for failure in failures:
			push_error("WALL_PANEL_GRAPHICAL: " + failure)
		print("WALL_PANEL_GRAPHICAL_RESULT: FAIL checks=%d failures=%d" % [checks, failures.size()])
		quit(1)

func _click(control: Control) -> void:
	_check(control.is_visible_in_tree(), "目标控件必须可见：%s" % control.get_class())
	var position := control.get_global_rect().get_center()
	for pressed in [true, false]:
		var event := InputEventMouseButton.new()
		event.button_index = MOUSE_BUTTON_LEFT
		event.pressed = pressed
		event.position = position
		event.global_position = position
		Input.parse_input_event(event)
		await process_frame
	await process_frame

func _type_text(text: String) -> void:
	for index in text.length():
		var key := _keycode(text[index])
		await _key(key, false, text.unicode_at(index))

func _key(keycode: Key, ctrl: bool = false, unicode: int = 0) -> void:
	for pressed in [true, false]:
		var event := InputEventKey.new()
		event.keycode = keycode
		event.unicode = unicode
		event.ctrl_pressed = ctrl
		event.pressed = pressed
		Input.parse_input_event(event)
		await process_frame
	await process_frame

func _keycode(character: String) -> Key:
	match character:
		"0": return KEY_0
		"1": return KEY_1
		"2": return KEY_2
		"3": return KEY_3
		"4": return KEY_4
		"5": return KEY_5
		"6": return KEY_6
		"7": return KEY_7
		"8": return KEY_8
		"9": return KEY_9
		".": return KEY_PERIOD
	return KEY_UNKNOWN

func _capture(tag: String) -> void:
	await process_frame
	await RenderingServer.frame_post_draw
	var image := root.get_texture().get_image()
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(CAPTURE_DIR))
	var path := CAPTURE_DIR + "/" + tag + ".png"
	_check(image.save_png(ProjectSettings.globalize_path(path)) == OK, "真实视口截图应保存：%s" % tag)
	print("WALL_PANEL_CAPTURE: %s" % ProjectSettings.globalize_path(path))

func _check(condition: bool, message: String) -> void:
	checks += 1
	if not condition:
		failures.append(message)
