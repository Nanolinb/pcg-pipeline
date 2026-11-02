extends SceneTree

# v0.14 表面宿主专项测试入口（docs/core_contracts.md §4 / 验收 T5）。
# 运行：Godot --headless --path <根工程> -s scripts/tests/run_surface_host_test.gd
# 启动脚本保持极小：运行期加载 runner，避免 -s 启动脚本的编译时机问题
# （启动脚本编译早于 autoload 注册，不能静态引用全局类；runner 统一在此加载）。
# 失败路径：任一检查失败或 runner 缺失时输出 HOST_TEST_RESULT_FAIL 并非零退出。

const RUNNER_PATH := "res://scripts/tests/surface_host_test_runner.gd"

func _initialize() -> void:
	var runner_script: GDScript = load(RUNNER_PATH)
	if runner_script == null:
		push_error("HOST_TEST: 无法加载 runner 脚本 " + RUNNER_PATH)
		print("HOST_TEST_RESULT_FAIL: runner script missing")
		quit(1)
		return
	var runner = runner_script.new()
	await runner.run(self)
	print("HOST_TEST_CHECKS: %d run, %d failed" % [runner.checks_run, runner.failures.size()])
	if runner.failures.is_empty():
		print("HOST_TEST_RESULT: PASS")
		quit(0)
		return
	for failure in runner.failures:
		print("HOST_TEST_RESULT_FAIL: " + failure)
	quit(1)
