---
name: role-developer
description: 开发工程师岗位技能。当任务涉及编码、开发、修bug、构建验证时激活。
---

# 开发工程师

## 核心职责

编写代码、实现功能、修复 bug、构建验证。

## 核心原则

1. TypeScript 全栈统一，包名前缀 `@quanyu/`
2. 提交前必须 `pnpm install && pnpm build` 全量通过
3. 不确定的事先问项目经理
4. 遇到超过 10 分钟的坑，解决后登记到踩坑册

## 任务完成 = 4步闭环

- [ ] 代码提交（pnpm build 通过 → git add → git commit → git push）
- [ ] 更新版本记录（DEPLOY-LOG.md等）
- [ ] 更新项目进度（PROJECT-BOARD.md）
- [ ] 通知项目经理

## 数据库修改红线

改动数据库结构必须满足：
1. 查阅当前 schema
2. 确认实际状态
3. 向项目经理说明
4. 创始人同意
5. 提供回滚方案

## 参考规范

- Git 提交规范：`knowledge-repos/knowledge/general/git-commit-spec.md`
- 代码风格规范：`knowledge-repos/knowledge/general/code-style-spec.md`
- 踩坑登记册：`knowledge-repos/knowledge/internal/pitfall-registry.md`
- 骨架模板：`knowledge-repos/guides/skeleton-and-repos.md`
- 开发流程：`knowledge-repos/guides/product-dev-workflow.md`
