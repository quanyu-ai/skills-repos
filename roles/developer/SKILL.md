---
name: role-developer
description: 开发工程师岗位技能。当任务涉及编码、开发、修bug、构建验证时激活。
---

# 开发工程师岗位技能

## 核心职责
编写代码、修复bug、构建验证、代码提交推送。

## 强制要求（每次执行任务前必读）

### 任务执行规范
- 一个任务只做一件事（不混杂写代码、build、部署）
- 不读大文件（直接用任务描述中给出的数据）
- 用 write 不用 sed 操作文件
- 完成后必须 commit + push

### 代码质量红线
- 禁止硬编码数据（页面必须接数据库）
- 原型转代码照搬不翻译（CSS原封不动，HTML只做语法转换）
- build 必须通过（提交前pnpm build验证）

## 任务完成 = 4步闭环
- [ ] 代码提交（build通过 → git add → git commit → git push）
- [ ] 更新记录（DEPLOY-LOG.md等）
- [ ] 更新项目进度（PROJECT-BOARD.md）
- [ ] 通知任务派发者

## 数据库修改红线
改动数据库结构必须满足：确认schema设计 → 说明变更原因 → 创始人同意 → 提供回滚方案。

## 技术栈约束

### 新依赖引入红线（PIT-030）
引入新 UI 库前必须验证 SSR 兼容性，详见 `knowledge/internal/pitfall-registry.md#PIT-030`。

### Next.js tRPC 页面结构（PIT-039）
页面必须拆成 server 组件（page.tsx）和 client 组件（client.tsx），详见 `knowledge/internal/pitfall-registry.md#PIT-039`。

### 原型转代码规范（PIT-031）
必须照搬而非翻译原型，详见 `knowledge/internal/pitfall-registry.md#PIT-031`。

## 参考文档
- 踩坑登记册：`knowledge/internal/pitfall-registry.md`
- 开发流程（v2.0，10步）：`guides/product-dev-workflow.md`
- 编码前确认：架构设计+功能详细设计（含交互层）已通过验收
### 禁止"开发中"占位（PIT-040 补充）
- 设计文档中定义了的功能，**必须实现**，不允许用 `alert('xxx开发中')` 占位
- 如果某功能确实无法实现（缺 API 等），必须在代码中注释说明原因，并在任务反馈中标注
- 按钮没有 onClick = 未完成，不允许提交
