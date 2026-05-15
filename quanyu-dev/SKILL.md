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

### DESIGN.md 设计规范（必读）
涉及 UI/前端代码编写时，**必须先读取当前项目目录下的 `DESIGN.md`**，严格遵循其中定义的设计 Token（颜色、字体、圆角、间距、组件样式）。

- 权舆官网(website): `quanyu-platform/DESIGN.md`
- 财税通(cst): `apps/cst/DESIGN.md`
- 拍记(paiji): `apps/paiji/DESIGN.md`

**规则：**
- 颜色必须使用 DESIGN.md 中定义的 Token，禁止自行发明颜色值
- 字体、圆角、间距优先使用 Token 定义的值
- 新增组件风格必须与 DESIGN.md 中的 Components 和 Do's and Don'ts 一致
- 如果 DESIGN.md 不存在，向项目经理反馈，不要自行创建

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
- [ ] UI 代码符合 DESIGN.md 设计规范（颜色/字体/圆角/间距）
- [ ] commit message 规范
- [ ] 已 push 到 GitHub

## 踩坑登记册重要条目
- PIT-034：新项目必须检查 tailwind.config.ts + postcss.config.js 是否存在
- PIT-031：原型转代码照搬不翻译，详见 `knowledge-repos/knowledge/internal/pitfall-registry.md#PIT-031`
- OCR/AI相关：PIT-033, PIT-035, PIT-036

## 技术栈
- 语言：TypeScript
- Web框架：Next.js 15 (App Router)
- UI：Tailwind CSS + shadcn/ui
- API：tRPC + superjson
- 数据库：PostgreSQL + Prisma
- 包管理：pnpm + Turborepo

## 参考文档
- 踩坑登记册：`knowledge-repos/knowledge/internal/pitfall-registry.md`
- 开发流程（v2.0，10步）：`knowledge-repos/guides/product-dev-workflow.md`
- 关键变化：Phase 3 架构设计、Phase 7 设计验收门禁、Phase 4 必须含交互层+数据层
- 骨架模板：`knowledge-repos/guides/skeleton-and-repos.md`
### 专业领域严谨原则（PIT-041）
- 涉及财税/法律/医疗等专业领域的功能，**不能拍脑袋，必须从权威渠道研究后再做**
- 权威渠道包括：国家税务总局官网、财政部官网、用友/金蝶等专业财务平台、会计准则文件、大量网络资源中可信度权重高的素材
- AI团队虽无专业资质，但有责任通过严谨研究给出有据可依的方案，而不是等专家来
- 宁可多花时间研究，也不能拍脑袋出错

### 前端 UI 修改流程（PIT-042，龙哥 2026-05-11 明确）

**适用场景**：任何涉及前端页面布局、样式、图标、控件的修改（尤其是参照设计稿还原）

**三步强制流程**：

#### Step 1：提取纯 UI 内容
- 从设计稿中只提取：颜色值、字体大小、间距、圆角、阴影、图标样式、布局结构、控件类型
- **绝对不提取**：文案内容、业务数据、按钮文字、标题文字、描述文字

#### Step 2：差异检查（必须通过才能继续）
- 对比修改前页面的所有元素，逐项确认：
  - [ ] 布局结构（区块数量、排列方式）是否匹配，不多不少
  - [ ] 样式（颜色/字体/间距/圆角）是否正确替换
  - [ ] 图标/控件是否与设计稿一致
  - [ ] **内容/文案/数据是否保持原样不变**
  - [ ] 不会因样式替换导致显示变形
- **不通过 → 停下来，向龙哥汇报差异并确认**
- **通过 → 继续 Step 3**

#### Step 3：执行替换
- 只替换：className、style、CSS 变量、图标组件
- **不替换**：文字内容、数据绑定、业务逻辑、trpc 调用

**红线**：
- ❌ 设计稿的示例文案（如"张财税"、"支付待结"）不能覆盖真实业务文案
- ❌ 设计稿的占位数据不能覆盖真实数据绑定
- ✅ 只动 CSS/className/style/图标，不动文字和逻辑

## 子 Agent 任务描述模板（必读）

派发开发任务给子 Agent 时，任务描述必须包含以下信息：

### 必填项
1. **改哪个文件**：绝对路径
2. **当前代码**：贴出需要修改的代码段
3. **目标代码**：贴出修改后的代码段
4. **改完做什么**：build 命令、部署命令、commit message
5. **环境信息**：DATABASE_URL、端口、Prisma Client 路径等

### 模板
```
## 任务：<简要描述>

### 修改文件
`<绝对路径>`

### 当前代码
<贴出当前代码>

### 修改为
<贴出目标代码>

### 完成后执行
1. pnpm build（在 quanyu-platform 根目录）
2. bash /opt/scripts/deploy-app.sh <app>
3. 部署后验证：pm2 env <id> | grep DATABASE_URL
4. 健康检查：curl -s -o /dev/null -w "%{http_code}" http://localhost:<PORT>
5. git add + commit + push（message: <commit message>）

### 环境信息
- 项目根目录：/var/lib/openclaw/.openclaw/workspace/code-repos/next-trpc-postgresql-platform/quanyu-platform
- DATABASE_URL：postgresql://quanyu:quanyu_dev_2026@localhost:5432/quanyu_paiji
- Prisma Client：node_modules/.pnpm/@prisma+client@5.22.0_prisma@5.22.0/node_modules/.prisma/client
```

### 反例（禁止）
- "请查看 schema.prisma 然后写一个 seed 脚本"
- "去研究一下 auth 模块然后修复 bug"
- "参考拍记的实现来做财税通"

### 正例（正确）
- "文件路径是 XX，当前第 42 行代码是 XX，改成 XX，改完执行 pnpm build"
