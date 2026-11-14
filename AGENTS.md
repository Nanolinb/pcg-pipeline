# 项目协作约定

## 版本管理（GitHub）

- 远程仓库：<https://github.com/Nanolinb/pcg-pipeline>（`main` 分支）。
- 每次完成功能修改：更新 `docs/changelog.md`（日期 + 主题 + 改动 + 验证），提交并推送到 GitHub。

## 修改记录与组件文档

- `docs/changelog.md` 记录项目级修改历史，按日期倒序。
- 每个组件一份文档，位于 `docs/component_docs/<组件>.md`，结构固定为：
  1. **目标**——组件要达成什么样的目标（含完整功能解释）。
  2. **修改记录**——按日期追加。
- 每次修改若涉及某个组件，须同步在该组件文档的「修改记录」追加一条；若修改明显改变了组件目标，同时修订「目标」一节。
- 新组件上线时，新建对应文档并登记到 `docs/component_docs/README.md` 清单。

## 腾讯文档同步

- 组件文档与发布说明同步到腾讯文档空间「PCG 建筑群编辑系统」：<https://docs.qq.com/space/DZWNhamhvUGtoQmRJ>。
- 本地 `docs/component_docs/` 为上传前的规范源；更新后提醒用户同步，或在获得 docs.qq.com 已登录的浏览器会话后代为上传。
