extends SceneTree

func _initialize() -> void:
	var runner_script: GDScript = load("res://scripts/tests/smoke_test_runner.gd")
	var main_scene: PackedScene = load("res://scenes/main.tscn")
	if main_scene == null or runner_script == null:
		push_error("SMOKE: 无法加载主场景或 smoke runner 脚本")
		quit(1)
		return
	var main := main_scene.instantiate()
	root.add_child(main)
	await process_frame
	await physics_frame
	var runner: RefCounted = runner_script.new()
	runner.main = main
	await runner.run()
