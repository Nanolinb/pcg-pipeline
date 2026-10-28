# v0.13 本机图形验收

日期：2026-10-29  
环境：Apple M3 Pro，macOS 26.6.2，Godot 4.6.2，GL Compatibility。

## G0_Component

命令：

```bash
/Applications/Godot.app/Contents/MacOS/Godot --path . -- --smoke-test
```

结果：`PCG_SMOKE_TEST_PASS`，真实图形输入路径通过。日志：`root_graphical_smoke_2026-10-29.log`。

视觉验收运行 `--visual-check`，拱形窗、过渡、材质面板和选择手柄可见。日志：

```text
PCG_VISUAL_FPS 116.0
PCG_DRAG_FPS 115.0
```

截图：`../golden/G0_arch_window_2026-10-29.jpg`。

这些 FPS 是工程即时日志，只作视觉场景参考，不等同于预热后 30 秒中位数/P95 性能验收。

根工程退出时仍有 GLES / RID / ObjectDB 清理警告，与既有问题一致；没有将功能 PASS 解释为泄漏已修复。

## G1_Pipe

全程只使用一个 PipeWeaver 图形实例。初始生成：

```text
PIPE_PCG_GENERATED length=3.775 vertices=625 connectors=4 segments=3
PIPE_PCG_READY
```

实际步骤与观察：

1. 滚动到 PBR 面板，BaseColor 显示“默认”，管体为默认暗青色。
2. 通过真实文件对话框选择 `pipe_texture_probe.png`。
3. 状态显示“管道共享 PBR 贴图已更新；AO 与 UV 保持独立。”，BaseColor 显示“已自定义”，管体变为测试贴的亮青蓝色。
4. 点击清除，BaseColor 恢复“默认”，管体恢复默认暗青色。
5. 点击“完成当前管道”，状态显示已完成 1 根且冻结。
6. 进入“选择”，点击管体，状态显示“已选中 1 根管道”。
7. 点击“重新编辑选中”，回到路径编辑，控制点恢复可见。

截图：

- `../golden/G1_pipe_custom_texture_2026-10-29.jpg`
- `../golden/G1_pipe_reedit_2026-10-29.jpg`

日志：`pipeweaver_graphical_2026-10-29.log`。PipeWeaver 正常关闭时无新增 Godot 清理错误。

## 结论

BASE-01 的图形操作、截图和本机 RID/对象证据已补齐。形式化 30 秒性能统计、P95 和内存趋势不属于 v0.13 既有小型场景的必要发布指标，保留到后续固定场景执行。
