# BASE-05 共享载体 Spike 报告：Material Profile 单源 addon

- 日期：2026-10-29
- 范围：v0.13.0 路线图 BASE-05（§5 与 §8 工作包 5），仅 Spike，不做全量迁移。
- Godot：4.6.2.stable.official（GL Compatibility），基线标签 v0.12.0-baseline。

## 1. 结论

**载体可行。** 独立共享 addon `shared/addons/pcg_shared/`（不属于任一主程序）经
`addons/pcg_shared` 目录符号链接被根工程、PipeWeaver、最小第三方消费者同时加载；
三个消费者均在**一次性测试副本**中完成 `.godot/` 清理后 `--import` 重导入，并运行
**同一份**测试脚本，全部通过；无重复 `class_name`、无 `uid://` 冲突、无 Autoload
冲突、无插件缓存冲突。统一门禁 `tools/run_gate.sh` 无回归。

## 2. 载体决策与理由

- **单源位置**：`shared/addons/pcg_shared/`（工作区级，独立 git 跟踪单元）。
- **加载方式**：各工程 `addons/pcg_shared -> <相对路径>/shared/addons/pcg_shared`
  符号链接。Godot 4.6 的文件系统扫描、`DirAccess`、资源导入均跟随目录符号链接，
  已实测确认（包括清理缓存后的冷导入）。
- **为什么不动现有 `scripts/material_profile.gd`**：两个主程序的 `.tres`
  （根工程 4 个、`PipeWeaver/assets/pipe_material.tres`）以**路径**而非 uid 引用
  `res://scripts/material_profile.gd`，移动文件会破坏现有资源；v0.13 要求现有
  资源行为不变，故 Spike 采用全新独立类名，把“替换本地副本”留到 v0.14 迁移。
- **插件**：`plugin.cfg` + 空 `@tool EditorPlugin`（`plugin.gd`）仅证明 addon
  描述文件可识别；`pcg_shared` 未加入任何工程的 `[editor_plugins] enabled`，
  headless 加载不依赖插件启用，全局类注册来自脚本扫描缓存。

## 3. 新增文件（未修改任何现有工程文件）

| 文件 | 作用 |
|---|---|
| `shared/addons/pcg_shared/plugin.cfg`、`plugin.gd` | addon 描述与空编辑器插件 |
| `shared/addons/pcg_shared/shared_material_profile.gd(.uid)` | `class_name PCGSharedMaterialProfile`，Resource，字段与语义哈希口径兼容路线图 §4.2 |
| `shared/addons/pcg_shared/material_profile_codec.gd(.uid)` | `class_name PCGSharedMaterialCodec`，save/load + 语义哈希（字典键排序、浮点 1e-5 量化） |
| `shared/addons/pcg_shared/tests/spike_check.gd(.uid)` | 三消费者共用的验证脚本 |
| `addons/pcg_shared`、`PipeWeaver/addons/pcg_shared`、`spike/base05_shared_addon/consumer/addons/pcg_shared` | 目录符号链接（相对路径，仓库内可移植） |
| `spike/base05_shared_addon/consumer/project.godot` | 最小第三方消费者（无主程序代码/资源） |
| `tools/run_shared_addon_spike.sh` | 可重复 Spike 验证命令 |

两个主程序的 `project.godot`、脚本、资源、`.godot/` 缓存均未改动。

## 4. 验证命令与结果

```bash
./tools/run_shared_addon_spike.sh   # 一次性副本：rsync（排除 .godot 等）→ 链接共享模块
                                    # → --headless --import 重导入 → -s spike_check.gd
./tools/run_gate.sh                 # 既有统一门禁
```

结果（2026-10-29，连续两轮一致）：

- `surface_component`：SPIKE 25/25 通过，`SPIKE_RESULT: PASS`
- `pipeweaver`：SPIKE 25/25 通过，`SPIKE_RESULT: PASS`
- `third_party_consumer`：SPIKE 23/23 通过（缺主程序“本地副本仍在”2 项专项，属预期）
- 阴性对照：共享模块断链时三消费者均失败（`NEGATIVE_CONTROL: OK`）
- `tools/run_gate.sh`：`GATE_PASS: all headless checks passed`，退出码 0

覆盖的检查项：模块文件可达；全局类缓存恰好注册一次且路径指向共享 addon；
全工程扫描零重复 `class_name`（根工程 28 脚本、PW 13、消费者 4）；
零重复 `.uid`（根工程 31、PW 14、消费者 4）；共享 uid 可被 `ResourceUID` 解析；
Autoload 无命名冲突（根工程/PW 均为 `MaterialLibrary`）；`plugin.cfg` 可解析；
资源 API（validate、build_material、to_dict/from_dict 往返、拒绝未来 format_version）；
codec 保存/加载往返一致；语义哈希确定且随内容变化；主程序本地
`PCGMaterialProfile` 与既有 `.tres` 加载不变；消费者隔离（无本地副本）。

## 5. 过程中发现与修复（均为验证代码问题，非载体问题）

- Godot `-s` 模式在脚本解析失败时**仍返回退出码 0**：门禁改为以日志
  `SPIKE_RESULT: PASS` 为准。这是 v0.14 起所有 `-s` 门禁的通用注意事项。
- `class_name` 是保留字，不可作变量名。
- rsync 副本必须排除工作区其它工程目录（PipeWeaver/spike/shared 等），
  否则跨工程同名类会被误判为重复。

## 6. 冲突清单（现状盘点，供 v0.14 迁移排序）

两工程间同名 `class_name` 重复（7 对，各占一个工程内唯一、跨工程重复）：
`PCGMaterialProfile`、`PCGMeshChunkBaker`、`PipeMeshBuilder`、`SurfacePathSolver`、
`PCGTextureSlotPanel`、`MaterialLibrary`（Autoload，两工程各一份）、
`material_library.gd`。根工程另有 `PipeWeaver` 未引用的管道脚本
（`pipe_mesh_builder.gd`、`surface_path_solver.gd`、`texture_slot_panel.gd` 等，
待 BASE-01 清单确认）。本 Spike 新增类 `PCGSharedMaterialProfile` /
`PCGSharedMaterialCodec` 与以上均不冲突。

## 7. 风险与限制

- 目录符号链接在 Godot 4.6 macOS 已实测可用；Windows 克隆需开发者模式/目录联接
  策略，v0.14 迁移前需在目标平台复测，或改用 CI 中的显式链接步骤。
- 各工程首次打开编辑器或导入时会重新扫描注册共享类；共享文件变更后依赖方工程
  需重新扫描（编辑器自动），headless 场景以 `--import` 为先。
- Spike 类为独立命名；v0.14 正式迁移 `PCGMaterialProfile` 时需处理 `.tres`
  路径引用（见 §8）。

## 8. v0.14 生产迁移建议

1. 以本 Spike 的 `shared/addons/pcg_shared/` 为迁移目标包，按 §6 清单逐个迁移；
   每迁移一个脚本，两个主程序同步删除本地副本并保留 addons 链接。
2. `PCGMaterialProfile` 迁移必须同时重写引用它的 `.tres`（当前按
   `res://scripts/material_profile.gd` 路径引用）：提供一次性迁移脚本把 ext_resource
   路径改到共享 addon（uid 引用更佳，需先在编辑器中重存资源生成 uid 引用）。
3. 统一 `MaterialLibrary` Autoload：迁到共享包后，两工程 `[autoload]` 指向同一
   `res://addons/pcg_shared/...`，名称保持 `MaterialLibrary`， Spike 已验证 Autoload
   名称冲突可检测。
4. 把 `tools/run_shared_addon_spike.sh` 的“日志断言”模式并入统一门禁
   （`tools/run_gate.sh`），防止 `-s` 假阳性；迁移期保持 Spike 测试常驻，
   重复 `class_name`/uid 扫描可作为 v0.14 的回归闸门。
5. 共享包正式启用编辑器插件（`plugin.gd` 挂 Inspector/导入钩子），并在
   `docs/requirements.md` 记录“禁止双向复制同步”的约束。
