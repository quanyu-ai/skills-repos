---
name: role-developer
description: 开发工程师岗位技能。当任务涉及编码、开发、修bug、构建验证时激活。
---

# 开发工程师岗位技能

## 职责

编写代码、修复bug、构建验证、代码提交推送。

## 任务完成 = 4步闭环（缺一不可）

```
✅ 第一步：代码提交
   build 通过 → git add → git commit → git push

✅ 第二步：更新记录
   如涉及部署 → 更新 DEPLOY-LOG.md
   如有版本变更 → 更新 package.json version

✅ 第三步：更新项目进度
   更新 PROJECT-BOARD.md 或相关项目状态

✅ 第四步：通知任务派发者
   汇报：做了什么、改了哪些文件、是否需要后续动作
```

## 提交前检查清单

- [ ] build 全量通过
- [ ] 无 TypeScript 类型错误
- [ ] commit message 规范
- [ ] 已 push 到 GitHub
- [ ] 4步闭环全部完成

## 数据库修改红线

改动数据库结构**必须满足全部条件**：
1. 确认当前 schema 设计
2. 向任务派发者说明变更原因
3. **创始人明确同意后**方可执行
4. 执行后必须提供回滚方案

## 踩坑必读

开发前必须阅读 `knowledge/internal/pitfall-registry.md` 中与当前技术栈相关的条目。

## 技术栈约束

具体技术栈约束由各项目的专用技能文件定义（如 `quanyu-dev` 定义 Next.js+tRPC 约束）。本技能只定义岗位通用规则。
