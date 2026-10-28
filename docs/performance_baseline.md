# 性能与测试环境基线

## 参考环境

| 项目 | 当前配置 |
|---|---|
| CPU | Apple M3 Pro |
| GPU | Apple M3 Pro，18 核，Metal 4 |
| 内存 | 38,654,705,664 bytes（约 36 GiB） |
| 操作系统 | macOS 26.6.2，build 25G83，arm64 |
| Godot | 4.6.2.stable.official.71f334935 |
| 渲染器 | GL Compatibility |
| 主显示 | 3024×1964 Retina |

更换硬件、Godot 确切版本、操作系统或渲染路径后，必须记录新环境并重录性能基线，不与旧环境直接比较。

## 测量口径

- 功能门禁：headless 数据/几何测试；失败必须返回非零退出码。
- 图形功能与真实输入：在本机图形会话单独运行，不用 headless Dummy Renderer 代替。
- 截图：本机图形会话归档并人工审核，不进入无显示环境门禁。
- 性能采样：先预热 3 次；交互测试采样 30 秒，记录中位数与 P95 帧时间；耗时操作同时记录中位数。
- 版本对比：只比较相同参考环境和相同场景，性能回退阈值为 10%。
- 资源基线：分别记录 headless 与图形模式；已知 Dummy Renderer 退出警告不得掩盖新增泄漏。

## 当前基线

- 根工程 headless smoke 已通过，功能日志见 `reports/baseline/root_smoke_2026-10-29.log`。
- PipeWeaver 当前启动与实际生成已通过，日志见 `reports/baseline/pipeweaver_startup_2026-10-29.log`。
- 本机图形输入、截图和 RID 证据已补齐，详见 `reports/baseline/graphical_acceptance.md`。
- G0 工程即时日志为视觉 116 FPS、拖动 115 FPS；该值只作参考。P95、30 秒中位数和内存趋势尚未测量，不声称通过这些后续性能指标。

## 后续固定场景指标

| 场景 | 指标 | 当前状态 |
|---|---|---|
| G0/G1 | 功能、网格统计、截图、资源基线 | v0.13 基线完成 |
| G3_Building | 单主体融合耗时、30 秒交互帧率 | 待场景引入 |
| G4_Block | 60 栋建筑，单地块更新时间目标 < 1s，交互目标 ≥ 30 FPS | 待场景引入 |
| G5_Districts | 流送延迟、内存、缓存命中、导航稳定 | 待场景引入 |
