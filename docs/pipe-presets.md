# PipeWeaver 管道预设规则

## 使用
- 资源目录：`PipeWeaver/assets/presets/`。
- 在“管道类型”中切换预设时，当前活动管道或全部选中管道立即替换。
- 替换只修改直径、材质、贴图、分段和优化参数，原路径、控制点、主体、角度、离墙偏移及 UV2 不变。
- 多选批量替换不增加“已完成管道”计数。

## 标准样本

| ID | 直径 | 环向 | 圆角 | 材质重点 |
|---|---:|---:|---:|---|
| industrial_water | 0.34m | 24 | 8 | 青色工业漆面 |
| high_pressure_steam | 0.48→0.40m | 32 | 12 | 深色厚壁高金属度 |
| copper_gas | 0.22m | 24 | 10 | 暖色铜质反射 |
| pvc_drain | 0.38m | 20 | 8 | 浅色非金属高粗糙度 |
| cable_conduit | 0.16m | 16 | 6 | 深色低反射护套 |

## 资源字段
- `id` / `display_name` / `description`：唯一标识、菜单名称和规则说明。
- `diameter` / `diameter_profile`：默认直径及按路径比例的分段直径；profile 中 `end` 必须递增，最后一项为 1。
- `radial_segments` / `default_corner_segments`：环向精度和默认圆角分段。
- `auto_optimize` / `texture_link`：自动直线减面及贴图步长联动。
- `straight_step` / `curve_step` / `straight_angle` / `manual_step`：自动优化与手动细分规则。
- `texture_world_size` / `detail_tiling` / `detail_strength` / `normal_strength`：Base UV 与 Detail 规则。
- `ao_strength`：默认 AO 强度，0 表示未启用；烘焙使用独立 UV2。
- `tint` / `metallic_offset` / `roughness_offset`：在共享 PBR 程序纹理上的材质偏移。

## 新增预设
1. 复制任意 `.tres` 样本并修改 ID 与名称。
2. 保持所有数值在说明范围内，直径必须大于 0，环向至少 8，圆角至少 2。
3. 将文件放入 `assets/presets/`，目录加载器会校验并自动加入菜单。
4. 若字段缺失或无效，加载器会返回具体文件错误，不使用无效样本。

所有样本均使用共享 Base/Detail/ORM 纹理；`tint` 只改变该预设自己的材质快照，不影响其他管道。
