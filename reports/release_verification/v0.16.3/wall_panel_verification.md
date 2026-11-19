# 墙板单元与融合预览验证

日期：2026-11-20  
环境：Apple M3 Pro，Godot 4.6.2，GL Compatibility，macOS

## 自动验证

```bash
./tools/run_gate.sh
```

结果：`GATE_PASS: all headless checks passed`。建筑 125 项、墙板 55 项、廊桥 112 项、宿主 224 项通过；PipeWeaver、编辑命令、资产任务、网格检查、标准资产发布、标准化窗口和共享包冷导入均通过。完整输出见 `gate.log`。

```bash
godot --path . -s scripts/tests/run_wall_panel_graphical_test.gd
```

结果：`WALL_PANEL_GRAPHICAL_RESULT: PASS checks=15`。通过真实输入队列完成单元预览点击、模数文本输入 2.5 m、确认融合和 Ctrl+Z；验证另一栋建筑节点始终不被重建。输出见 `graphical.log`。

## 截图

- `wall_panel_preview.png`：墙板单元预览，细缝显示分板边界，右侧参数完整且无横向裁切。
- `wall_panel_fused.png`：模数 2.5 m 下确认融合，恢复整栋墙面；门窗、廊桥与平面数据保持原求解结果。

## 用户复验

1. 打开建筑平面工作台，选择 `house_l`。
2. 在右侧“墙板与融合”勾选“墙板单元预览”，确认只重建当前建筑并出现单元细缝。
3. 将墙板模数改为 2.5 m，观察单元布局更新而门窗和廊桥不跳动。
4. 点击“确认并融合整栋墙板”，确认细缝消失；按 Ctrl/Cmd+Z 应恢复预览，再撤销一次恢复先前模数。
5. 需要合并不同建筑时，仍使用左侧“融合选中建筑轮廓”，不要与墙板融合混用。

## 已知边界

- 本次是派生槽位和显示切片，不是完整 `ComponentSlot`、L0 候选、L1 发布或 `SlotBinding` 闭环。
- 单个派生墙板不是可直接发布的封闭标准资产；预览细缝不属于融合后的实体几何。
- 尚未实现逐墙板选择、可破坏标记、独立楼板、入口楼梯、外廊或坡屋顶；后续顺序见 `docs/roadmap.md`。
- 本次未新增性能采样；性能仍按 `docs/performance_baseline.md` 的固定场景单独验收。

反馈时请附上操作步骤、选中建筑、墙板模数、预期/实际结果及对应截图或日志。
