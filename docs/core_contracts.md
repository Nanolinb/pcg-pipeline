# v0.14 公共核心契约

本文是 BASE-06 的评审结果，冻结 v0.14 开始实现的最小字段和语义。只覆盖公共内核，不提前定义建筑样本或城市生成字段。

## 1. 持久化与稳定 ID

### 1.1 稳定 ID

| 字段 | 类型 | 规则 |
|---|---|---|
| `id` | StringName | 发布后不变；使用小写 ASCII 字母、数字、下划线或连字符 |
| `id_version` | int | ID schema 版本，当前为 1 |
| `created_with` | String | 创建时的应用版本，仅用于审计，不参与签名 |
| `display_name` | String | 可修改，不参与签名 |

ID 不依赖 NodePath、节点名称或文件显示名。资源移动时使用迁移器更新引用，不复用旧 ID 表示不同语义。

### 1.2 格式版本与迁移

每份持久化文档包含：

```text
format_version: int
app_version: String
payload: Dictionary
```

加载顺序固定为：

```text
读取 → 检查 format_version → 逐级迁移 → 字段校验 → 构建
```

- 迁移接口：`migrate(document: Dictionary, from_version: int) -> Dictionary`。
- `from_version` 高于当前版本时，返回“版本过新”错误，不静默解释。
- 新字段以追加方式加入并提供默认值；重命名、删除或语义变化必须提升格式版本。
- 每次迁移至少保留一个旧版测试文档，迁移后的语义哈希必须通过黄金回归。
- 校验失败时列出字段错误，不生成半份场景。

## 2. 编辑命令

```text
PCGEditCommand
  command_id: StringName
  target_id: StringName
  scope: Dictionary
  before: Dictionary
  after: Dictionary
  merge_key: StringName
  timestamp_ms: int
```

- 所有编辑经 Godot UndoRedo 提交，do/undo/redo 共用同一个补丁应用入口。
- 补丁只包含受影响字段，不以 NodePath 作为稳定身份。
- 同一目标连续拖动使用相同 `merge_key`，在 800ms 窗口内且中间无其他命令时合并为一条历史。
- `before/after` 使用统一规范化序列化，命令流可以哈希和审计。
- v0.14 的首个真实消费者是根工程；PipeWeaver 现有内存 history 在 v0.19 通过适配器迁移，不在本版本同时重写两个主程序。

## 3. 确定性随机流

作用域键为：

```text
world / district / parcel / building / assembly / purpose
```

派生方案版本为 1：

```text
stream_key  = 规范化作用域路径
stream_seed = SHA256("pcg-rng/v1\n" + master_seed + "\n" + stream_key) 的前 8 字节
```

- 每个作用域使用独立 RandomNumberGenerator，禁止业务代码调用全局随机状态。
- 新增作用域只允许追加键，不改变既有键的文本和派生算法。
- 同一流内的采样调用顺序属于生成行为；改变调用顺序视为输入变化。
- 使用随机结果时，主种子、派生方案版本和作用域必须可恢复。
- `purpose` 的合法值以追加方式扩展，不改变既有用途的含义。

## 4. 表面宿主接口

```text
PCGSurfaceHost
  host_id: StringName
  surface_kind: int
  surface_transform(anchor: Vector2) -> Transform3D
  surface_distance(a: Vector2, b: Vector2) -> float
  surface_raycast(origin: Vector3, direction: Vector3) -> Dictionary
  surface_frame(anchor: Vector2) -> Dictionary
  host_path_data() -> Dictionary
  occupancy_query(region: Dictionary) -> Array
  register_component(component_id: StringName, anchor: Vector2) -> void
  unregister_component(component_id: StringName) -> void
```

- 锚点使用宿主局部表面坐标；世界坐标只出现在适配器边界。
- 核心不引用具体 CSG 或主程序节点类型，适配器可以持有这些引用。
- `surface_kind` 只允许追加枚举值，不改变已有值。
- `host_path_data` 和 `occupancy_query` 在 v0.14 可以先返回空数据，但返回结构必须稳定。
- 平面、圆柱、半球圆柱通过适配器接入，既有 G0 行为不得改变。

## 5. 规范化与重建签名

### 5.1 规范化序列化

- 字典键按文本排序，数组保持顺序并记录长度。
- 浮点统一量化到 `1e-5`，使用定点文本，禁止依赖区域设置或 `%g`。
- 派生值不替代原始输入。例如实际缩放必须保留 `user_scale` 和 `neighborhood_scale` 两个输入。
- 语义哈希使用规范化结果的 SHA-256；网格哈希另行记录顶点、索引和材质槽。

### 5.2 签名

```text
RebuildSignature
  format_version: int = 1
  generator_id: StringName
  generator_version: int
  host_signature: String
  param_digest: String
  seed_digest: String
  digest: String
```

- `generator_id` 示例：`transition_mesh/v1`。
- `generator_version` 在生成语义变化时递增，与文档格式版本分开。
- `host_signature` 只包含会影响结果的主体几何输入。
- 使用随机时写入派生种子摘要，否则为空。
- 缓存键为 `digest`；同签名命中，任一有效输入变化都必须失效。

## 6. 原子保存与恢复

1. 在目标文件同目录写入临时文件，flush 并关闭。
2. 替换前保留最近一份正式文件为 `.bak1`。
3. 使用同文件系统原子替换提交正式文件。
4. 临时文件残留但正式文件完整时，清理临时文件并记录，不改变正式数据。
5. 正式文件损坏且备份存在时，提示用户恢复；不得静默覆盖或自动丢弃最近一致状态。
6. 测试通过保存故障注入模拟中断，不依赖强制终止 Godot 进程。

## 7. 共享包边界

共享包只包含：

- 契约 Resource 和纯数据。
- 编辑命令与规范化序列化。
- 随机派生和重建签名。
- 表面宿主接口。
- 格式迁移与校验。

共享包不包含主程序 UI、具体 CSG 节点或 EditorPlugin 业务逻辑。唯一物理目录为根工程 `addons/pcg_shared/`；PipeWeaver 和测试消费者通过同名链接使用，禁止双向复制同步，也不得再暴露第二条 `res://shared/` 资源路径。

PipeWeaver 快照字段在 v0.19 随消费者冻结；v0.14 只复用格式版本和迁移接口。内存 `pipe_records` 不得被误称为已有磁盘快照格式。

## 8. 验收测试

| ID | 验收 |
|---|---|
| T1 | 根工程、PipeWeaver、第三消费者加载同一共享包；核心类名和 UID 无冲突 |
| T2 | 创建组件→改参数→撤销→重做完整恢复；一次拖动只有一条历史 |
| T3 | 写入中断后恢复最近一致数据，备份和恢复提示存在 |
| T4 | 每作用域重复抽样 1000 次一致；A 分支变化不影响 B；追加作用域不改变旧序列 |
| T5 | 新测试宿主只实现适配器即可复用组件与路径核心，G0 行为不变 |
| T6 | 同签名缓存命中；参数变化只使对应对象失效，无关 Mesh 实例不变 |
| T7 | `1.0` 与 `1.0000001` 的量化结果一致，`1.0` 与 `1.00001` 的量化结果不同 |
| T8 | 旧格式逐级迁移后哈希一致；未来格式返回可读错误 |
| T9 | v0.13 场景和文档 round-trip 无字段丢失 |
| T10 | 命令 do→undo→redo 后补丁哈希和场景状态一致 |
