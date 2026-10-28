# v0.13 BASE-01 基线记录

日期：2026-10-29（本机）

## 工程与源码状态

- Surface Component PCG：`0.12.0`。
- PipeWeaver：已补 `config/version="0.12.0"`，与集成基线对齐。
- Godot：`4.6.2.stable.official.71f334935`。
- 开始 BASE-01 时 PipeWeaver 存在未提交修改，本次未覆盖、回退或清理这些修改。

起始修改文件：

- `PipeWeaver/scripts/main.gd`
- `PipeWeaver/scripts/material_library.gd`
- `PipeWeaver/shaders/pipe_grid.gdshader`

起始未跟踪文件：

- `PipeWeaver/assets/pipe_material.tres`
- `PipeWeaver/scripts/material_profile.gd` 及 `.uid`
- `PipeWeaver/scripts/texture_slot_panel.gd` 及 `.uid`

这些修改引入 PipeWeaver Material Profile、贴图槽、共享材质更新和 Tint。当前没有独立 PipeWeaver 嵌套 Git 仓库。

## 文件证据哈希（SHA-256）

```text
4f383fd8eae24184c5ab60dbef3814c422eae838274b53e335a00808c343e9b5  PipeWeaver/scripts/main.gd
fb8574fc9e57fdaee7c075671d10bdf6ddba2fa3d0fa63ee4ad664a488784b34  PipeWeaver/scripts/material_library.gd
4298900a1d769f63353833adbad46a97b6066db698a90c8c2e59a5d1deb5767d  PipeWeaver/shaders/pipe_grid.gdshader
92289b4b637f7e32d623794acc7c2d1146ae8e7bc4b90988432078042310de72  PipeWeaver/assets/pipe_material.tres
fb883aaa63850e3a83a1a4335213a8f3ac99ef63d7fba69b596081bbb6510628  PipeWeaver/scripts/material_profile.gd
b85d7d36b46777e3ac5aa9be70191c5e78d386c0e48f4b536cd5c326db744067  PipeWeaver/scripts/texture_slot_panel.gd
f06d537e29dfce37cc78b0b75ed638a06f6107379a9341d8a9949a9c7d6f426d  PipeWeaver/project.godot
```

## 实际运行结果

### G0_Component：根工程 headless smoke

命令：

```bash
/Applications/Godot.app/Contents/MacOS/Godot --headless --path . -- --smoke-test
```

结果：进程退出码 0，功能通过。

```text
PCG_SMOKE_TEST_PASS: dual hosts, smoothed CSG render, visible wireframe material, snapping, handles, isolated shrink
```

日志：`root_smoke_2026-10-29.log`。

既有退出警告：Dummy Renderer / PagedAllocator / ObjectDB / Resource 清理警告。这些警告在既有 changelog 中已有记录，本次作为基线保留，后续门禁应识别新增泄漏而不是把它们静默忽略。

### G1_Pipe：PipeWeaver 当前启动与生成

命令：

```bash
/Applications/Godot.app/Contents/MacOS/Godot --headless --path PipeWeaver --quit-after 3
```

结果：进程退出码 0。

```text
PIPE_PCG_GENERATED length=3.775 vertices=625 connectors=4 segments=3
PIPE_PCG_READY
```

日志：`pipeweaver_startup_2026-10-29.log`。

该结果验证当前材质修改未阻止工程解析、初始化和实际管道生成。它还不等同于完整 headless 交互回归；路径、跨主体、重编辑和合批由 BASE-03 覆盖。

## 快照与共享代码事实

- 当前 PipeWeaver `pipe_records` 是内存重编辑数据，不是磁盘快照格式。
- 当前记录字段包括：root、points、normals、hard_corners、angles、corner_segments、wall_offsets、colliders、segments、radial_segments、texture_world_size、clearance、default_corner_segments、optimization、detail_tiling、detail_strength、normal_strength、ao_strength、ao_texture、finalized、baked。
- 两个独立工程存在同名核心类；现状不冲突，但共享包迁移后必须保证共享包内类名唯一。
- 根工程存在未被主程序引用的管道文件；BASE-01 只登记，不在基线阶段删除。

## 尚未完成的 BASE-01 证据

- 本机图形会话中的 PipeWeaver 材质填入、清除回退、重编辑和截图人工复测。
- 根工程与 PipeWeaver 图形模式 RID/对象基线。
- G0/G1 截图黄金样本。

上述项目不伪记为通过，也不进入 headless 自动门禁。

## BASE-02～04 后续验证

- 根工程独立入口：`Godot --headless --path . -s scripts/tests/run_smoke_test.gd`，通过；原 `-- --smoke-test` 兼容入口也通过。
- PipeWeaver 独立入口：`Godot --headless --path PipeWeaver res://tests/pipeweaver_smoke.tscn`，结果 `PIPE_SMOKE_PASS checks=56`。
- PipeWeaver 多 Surface 合批已使用 `surface_index + old_index`，专项测试验证两个 Surface 的相同旧索引保留各自顶点位置。
- 统一门禁：`tools/run_gate.sh`，双工程版本和全部 headless 检查通过。
- 两个测试入口均做过失败注入并确认非零退出，探针已还原并复跑通过。
- 根工程退出警告与既有基线一致；PipeWeaver 当前测试无新增退出错误。
