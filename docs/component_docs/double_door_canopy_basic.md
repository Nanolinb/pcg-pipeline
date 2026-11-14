# 双门出口 · 带遮阳顶（double_door_canopy_basic）

## 目标

为需要更显眼入口的建筑提供双门带遮阳顶组件。

- **资源**：`assets/building_components/double_door_canopy_basic.tres`，角色 `DOUBLE_DOOR`，几何 `DOUBLE_DOOR`，尺寸 2.05 × 2.55 × 1.05 m，框架宽 0.12 m。
- **材质槽**：门框（`building/entrance/double_frame`）、双门板（`building/entrance/double_panels`）。
- **结构**：门框、双门板和遮阳顶共用同一原点，包含真实几何而非贴图表达。
- **启用方式**：由 `use_double_entrance` 显式替换普通单门入口；双门遮阳顶纳入占用检查。

## 修改记录

### 2026-11-13 · 建筑装饰标准组件扩充
- 新增组件；`use_double_entrance` 可显式替换单门。

### 2026-11-13 · 建筑装饰冲突修复与选中建筑修复
- 入口改为候选立面选择规则，双门遮阳顶纳入占用。
