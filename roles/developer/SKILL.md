---
name: role-developer
description: 开发工程师岗位技能。当任务涉及编码、开发、修bug、构建验证时激活。
---

# 开发工程师岗位技能

## 职责

编写代码、修复bug、构建验证、代码提交推送。

## 强制要求（每次执行任务前必读）

### 任务执行规范
1. **一个任务只做一件事**：不要在同一个任务中又写代码又 build 又部署，除非任务描述明确要求
2. **不读大文件**：如果任务描述中已经给了数据/类名/模板，直接用，不要自己去读原型文件
3. **用 write 不用 sed**：写整个文件用 write，不要用 sed 操作大文件
4. **完成后必须 commit**：git add + git commit，不能只写文件不提交

### 代码质量红线
1. **禁止硬编码数据**：所有页面必须接数据库，不允许写死示例数据（除非任务明确说“用静态数据”）
2. **原型转代码照搬不翻译**：CSS 原封不动复制，HTML 只做语法转换
3. **build 必须通过**：提交前必须 pnpm build 通过，不能留下编译错误

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

## 原型转代码规范（PIT-031）

有原型 HTML 文件时，必须 **照搬** 而不是 **翻译**：

1. **CSS**：原型 `<style>` 中的 CSS **原封不动**复制到 `globals.css`
2. **HTML → JSX**：只做语法转换，不改结构、不改类名、不加 inline style
   - `class` → `className`
   - `onclick` → `onClick`
   - `style="..."` → `style={{...}}`
   - SVG 属性驼峰（`stroke-width` → `strokeWidth`）
3. **禁止行为**：
   - ❌ 用不同的 Tailwind 类名重写原型样式
   - ❌ 改变 HTML 层级结构
   - ❌ 自己发明包裹层（如 `<div style={{ display: 'flex', height: 'calc...' }}>`）
4. **验证**：完成后对比原型截图 vs 实现截图，差异必须说明原因

## 数据库对接规范

**新页面开发必须同步对接数据库，禁止硬编码数据。**

开发顺序：
1. 确认数据库 schema（Prisma model）
2. 写/确认 tRPC API（router + procedure）
3. 前端页面调用 tRPC 查询/写入
4. 插入样例数据用于测试

**绝对禁止**：写死示例数据在前端代码里（如 `const records = [{id: 1, amount: 500, ...}]`）

## 踩坑必读

开发前必须阅读 `knowledge/internal/pitfall-registry.md` 中与当前技术栈相关的条目。

## 技术栈约束

具体技术栈约束由各项目的专用技能文件定义（如 `quanyu-dev` 定义 Next.js+tRPC 约束）。本技能只定义岗位通用规则。

### 新依赖引入红线（PIT-030）
- 引入新 UI 组件库前，**必须先建最小 demo 验证 SSR 兼容性**
- 不在主项目上直接引入未验证的库
- 验证方法：新库引入 → build → standalone 部署 → 浏览器访问

### Next.js tRPC 页面结构（PIT-039，必须遵守）
所有使用 tRPC 的页面**必须**拆成两层：
- `page.tsx`（server 组件）：`export const dynamic = 'force-dynamic';` + 导入 client 组件
- `client.tsx`（client 组件）：`'use client'` + tRPC 调用 + 页面 UI
**禁止**：在 `page.tsx` 中直接写 `'use client'` + tRPC 调用
