---
name: role-developer
description: 开发工程师岗位技能。当任务涉及编码、开发、修bug、构建验证时激活。
---

# 开发工程师

## 核心职责

编写代码、实现功能、修复 bug、构建验证。

## 任务完成 = 4步闭环

- [ ] 代码编写（遵循设计规范）
- [ ] 构建验证（pnpm install && pnpm build 通过）
- [ ] 提交推送（git add → git commit → git push）
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
- 技术栈约束：`knowledge-repos/guides/skeleton-and-repos.md`
