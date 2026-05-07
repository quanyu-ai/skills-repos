---
name: quanyu-dev
description: 权舆科技开发技能。当任务涉及编码、开发、修bug、tRPC、Next.js、Prisma、TypeScript、pnpm build、代码审查、构建验证时激活。
---

# 权舆科技开发技能

## 核心原则

1. TypeScript 全栈统一，包名前缀 `@quanyu/`
2. 提交前必须 `pnpm install && pnpm build` 全量通过
3. 不确定的事先问项目经理
4. 遇到超过 10 分钟的坑，解决后登记到踩坑册

## 任务完成 = 4步闭环（缺一不可）

**完成任何开发任务后，必须依次执行，不需要任何人提醒：**

```
✅ 第一步：代码提交
   pnpm build 通过 → git add → git commit → git push

✅ 第二步：更新版本记录
   如涉及部署 → 更新 DEPLOY-LOG.md
   如有版本变更 → 更新 package.json version

✅ 第三步：更新项目进度
   更新 PROJECT-BOARD.md 或相关项目的状态

✅ 第四步：通知项目经理
   汇报完成情况：做了什么、改了哪些文件、是否需要后续动作
```

**遗漏任何一步 = 任务未完成。**

## 数据库修改红线（绝对禁止！）

改动数据库结构（新增/删除/修改字段、新建/删除表）**必须满足全部条件**：

1. 查阅当前 Prisma schema，确认最新设计
2. 确认数据库当前实际状态
3. 向项目经理说明：为什么要改、改什么、是否符合现有设计
4. **创始人明确同意后**方可执行
5. 执行后必须 `prisma generate` + 提供回滚方案

**未经创始人同意直接改数据库 → 立即回退。**

## 强制约束（违反即不合格）

### tRPC（PIT-001）
- 写入：`const mutation = trpc.xxx.useMutation()` + `mutation.mutateAsync()`
- 查询：`const { data } = trpc.xxx.useQuery()` 直接解构
- **禁止**：`onSuccess` 回调、`.mutate()` 直接调用

### Prisma（PIT-002, PIT-006）
- 枚举值从 Prisma 类型导入，**禁止手写字符串**
- 修改 schema 后**必须** `prisma generate`
- 必填字段不能遗漏

### Next.js 15（PIT-003, PIT-004, PIT-005）
- `useSearchParams()` **必须**包 `<Suspense>` 边界
- `next.config` **必须**有 `transpilePackages`（列出所有 `@quanyu/*` 依赖）
- tRPC 客户端 `httpBatchLink` **必须**配 `transformer: superjson`
- Docker 部署时 `next.config` **必须**有 `output: 'standalone'`

### TypeScript（PIT-007）
- catch 块统一 `catch (error: any)` 或类型守卫
- 访问 error 属性前：`error?.message || String(error)`

### npm 镜像源
- Dockerfile 中必须配置 `registry https://registry.npmmirror.com`

### 版本号禁令
- **禁止硬编码 fallback 版本号**（如 `version || '1.0.0'`）
- 版本号必须动态读取 package.json

## 提交前检查清单

- [ ] `pnpm install` 无报错
- [ ] `pnpm build` **全量**构建通过
- [ ] 无 TypeScript 类型错误
- [ ] commit message 规范：`feat:/fix:/docs:/refactor:/chore:/release:`
- [ ] 已 push 到 GitHub
- [ ] 4步闭环全部完成

## 代码审查检查清单

- [ ] 无 `onSuccess` 回调或 `.mutate()` 直接调用
- [ ] 无手写枚举字符串
- [ ] `useSearchParams` 有 Suspense 边界
- [ ] Next.js 有 `transpilePackages`
- [ ] tRPC 客户端有 `transformer: superjson`
- [ ] catch 块有类型标注
- [ ] 无硬编码版本号
- [ ] `pnpm build` 全量通过
- [ ] 无未经审批的数据库结构变更

## 常见错误速查

| 错误现象 | 根因 | 解决 |
|---------|------|------|
| `onSuccess` 不存在 | React Query v5 移除 | 用 useQuery 返回的 data |
| `.mutate()` 不存在 | tRPC React 不暴露 | 用 useMutation + mutateAsync |
| 枚举类型不匹配 | 大小写不一致 | 从 Prisma 类型导入 |
| useSearchParams CSR bailout | Next.js 15 要求 | 包 Suspense 边界 |
| 找不到 workspace 包 | 缺 transpilePackages | next.config 加配置 |
| transformer 不匹配 | 前后端不一致 | 客户端加 superjson |
| prisma client 未初始化 | 没跑 generate | prisma generate |
| Docker build npm 超时 | 未配镜像源 | 加 npmmirror.com |

## 踩坑登记册

完整条目见 `knowledge/internal/pitfall-registry.md`。
开发前**必须**阅读相关条目。发现新坑时登记。

### Tailwind 必读（PIT-015~018, PIT-034）
- PIT-015：content 路径必须覆盖 src/ 目录
- PIT-016：自定义颜色必须用 `<alpha-value>` 格式
- PIT-017：code-icon 类和 span 内容不要混用
- PIT-018：postcss.config.js 不能缺
- PIT-019：原型转代码要逐个 section 对照 checklist
- **PIT-034：新项目必须检查 tailwind.config.ts + postcss.config.js 是否存在！缺失会导致所有 Tailwind 类名静默失效**

### OCR/AI 必读（PIT-033, PIT-035, PIT-036）
- PIT-033：PaddleOCR v3.5 API 完全不兼容旧版，用 `predict()` + `rec_texts`
- PIT-035：前端图片压缩质量不能低于 0.9，宽度不能低于 1500px
- PIT-036：金额提取不能用 Math.max，必须按优先级匹配（小写 > 合计 > ¥ > 第二大）

### 原型转代码必读（PIT-031）
- **照搬不翻译**：原型 CSS 原封不动复制，HTML 只做语法转换
- 禁止自己用不同的 Tailwind 类名重写原型样式
- 完成后必须对比原型截图验证

## 技术栈约束

| 层面 | 选择 |
|------|------|
| 语言 | TypeScript |
| Web框架 | Next.js 15 (App Router) |
| UI | Tailwind CSS + shadcn/ui |
| API | tRPC + superjson |
| 数据库 | PostgreSQL + Prisma |
| 包管理 | pnpm + Turborepo |
| Monorepo | `@quanyu/` 前缀 |

新增依赖或偏离技术栈**必须**经技术总监评估 + 创始人确认。

## 骨架模板与新项目

- **新项目必须从对应技术栈的骨架仓库 fork，禁止从零搭建**
- 主栈骨架：`skeleton-next-trpc-postgresql`（Next.js + tRPC + Prisma + PostgreSQL）
- 独立项目骨架：`skeleton-vue-express-mysql`（Vue + Express + MySQL）
- 骨架维护：从主项目单向提炼通用改进，不反向回写
- 详见 `guides/skeleton-and-repos.md`

## 新项目初始化检查清单

从骨架创建新项目后，必须检查：

- [ ] `tailwind.config.ts` 存在且 content 路径正确
- [ ] `postcss.config.js` 存在
- [ ] `tailwindcss` + `autoprefixer` + `postcss` 在 devDependencies 中
- [ ] `pnpm build` 通过
- [ ] 浏览器访问页面，确认 Tailwind 类名生效（如 `flex`、`grid` 布局正常）
- [ ] 数据库连接正常（Prisma migrate / seed）
