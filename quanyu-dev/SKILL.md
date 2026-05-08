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

## 任务完成 = 4步闭环
- [ ] 代码提交（pnpm build 通过 → git add → git commit → git push）
- [ ] 更新版本记录（DEPLOY-LOG.md等）
- [ ] 更新项目进度（PROJECT-BOARD.md）
- [ ] 通知项目经理

## 数据库修改红线
改动数据库结构必须满足：查阅当前schema → 确认实际状态 → 向项目经理说明 → 创始人同意 → 提供回滚方案

## 强制约束

### tRPC（PIT-001）
写入用 `useMutation()` + `mutateAsync()`，查询用 `useQuery()` 直接解构，禁止 `onSuccess` 回调。

### Prisma（PIT-002, PIT-006）
枚举值从 Prisma 类型导入，禁止手写字符串；修改schema后必须 `prisma generate`。

### Next.js 15（PIT-003, PIT-004, PIT-005）
- `useSearchParams()` 必须包 `<Suspense>` 边界
- `next.config` 必须有 `transpilePackages`（列出所有 `@quanyu/*` 依赖）
- tRPC 客户端 `httpBatchLink` 必须配 `transformer: superjson`
- Docker 部署时 `next.config` 必须有 `output: 'standalone'`

### TypeScript（PIT-007）
catch 块统一 `catch (error: any)` 或类型守卫，访问 error 属性前：`error?.message || String(error)`

### 其他约束
- Dockerfile 中必须配置 `registry https://registry.npmmirror.com`
- 禁止硬编码 fallback 版本号

## 提交前检查清单
- [ ] `pnpm install` 无报错
- [ ] `pnpm build` 全量构建通过
- [ ] 无 TypeScript 类型错误
- [ ] commit message 规范
- [ ] 已 push 到 GitHub

## 踩坑登记册重要条目
- PIT-034：新项目必须检查 tailwind.config.ts + postcss.config.js 是否存在
- PIT-031：原型转代码照搬不翻译，详见 `knowledge/internal/pitfall-registry.md#PIT-031`
- OCR/AI相关：PIT-033, PIT-035, PIT-036

## 技术栈
- 语言：TypeScript
- Web框架：Next.js 15 (App Router)
- UI：Tailwind CSS + shadcn/ui
- API：tRPC + superjson
- 数据库：PostgreSQL + Prisma
- 包管理：pnpm + Turborepo

## 参考文档
- 踩坑登记册：`knowledge/internal/pitfall-registry.md`
- 开发流程（v2.0，10步）：`guides/product-dev-workflow.md`
- 关键变化：Phase 3 架构设计、Phase 7 设计验收门禁、Phase 4 必须含交互层+数据层
- 骨架模板：`guides/skeleton-and-repos.md`
### 专业领域红线（PIT-041）
- 涉及财税/法律/医疗等专业领域的功能，**必须有专业人士审核后才能上线**
- AI 团队不具备专业资质，不能自己拍脑袋定规则
- 宁可不做，也不能做错
