# 窗外晾衣杆 · 有衣服（window_drying_clothes_basic）

## 目标

为上层立面窗户提供带衣物的窗外晾衣杆，增强生活氛围。

- **资源**：`assets/building_components/window_drying_clothes_basic.tres`，角色 `WINDOW_DRYING_ROD`，几何 `WINDOW_DRYING_CLOTHES`，尺寸 1.35 × 1.1 × 1.0 m。
- **材质槽**：晾衣杆（`building/facade/drying_rod`）与衣物（`building/facade/drying_clothes`）使用独立共享材质 Surface。
- **几何要求**：衣物布片保留间隙，不与杆体共享非流形边。
- **占用规则**：同空杆版本——参与统一占用与凹角净空检查，宿主窗户不合法时不生成。

## 修改记录

### 2026-11-13 · 建筑装饰标准组件扩充
- 新增组件；通过封闭性、非流形、退化面、法线和 UV0 检查。

### 2026-11-13 · 建筑装饰冲突修复与选中建筑修复
- 纳入 AABB 占用与凹角净空检查，记录宿主窗户槽位。

### 2026-11-13 · 门窗纳入选中建筑修复
- 不合法窗户不再生成其晾衣杆。
