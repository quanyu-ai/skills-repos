# dispatch-task - 设计说明 + 派单模板

## 为什么需要这个 skill

主Agent（呆呆）会反复在以下场景翻车：

1. 派子 Agent 时任务描述含糊（"读 XX 文件然后改一下"）→ 子 Agent 反复探索 → 超时
2. 没给绝对路径 → 子 Agent 猜路径 → 改错地方
3. 没说清楚改完要 build / 部署 / commit → 子 Agent 只改了文件就回来 → 主Agent 又得二次派单
4. 生成大文件没说 write-large-file.sh → 子 Agent 用 OpenClaw write 触发 10KB 截断（踩坑：2026-05-23 005D）
5. 没登记 TASK-TRACKER → 派完忘了销账 → 后续审计抓出来

这个 skill 把上述 5 个坑固化成"派发前必检脚本 + 派单模板"，避免靠人脑记。

## 文件结构

```
dispatch-task/
├── SKILL.md                       # 触发条件 + 红线 + 工具索引
├── README.md                      # 本文件
└── scripts/
    ├── check-task-desc.sh         # 任务描述合规性校验
    ├── pre-dispatch.sh            # 5 项必检（含 TASK-TRACKER 登记检查）
    └── dispatch-template.sh       # 输出标准派单模板
```

## 标准派单模板 5 种

通过 `bash scripts/dispatch-template.sh <type>` 打印。

### type=dev（开发任务）

```markdown
## 任务 TASK-YYYYMMDD-NNN：<标题>

### 工作目录
`<项目绝对路径>`

### 当前状态（已内联，不用查文件）
- 关键文件：`<绝对路径>`
- 当前代码片段：
  ```
  <内联当前代码>
  ```

### 目标
- 改成：
  ```
  <内联目标代码>
  ```

### 完整执行链路
1. 编辑文件 → 2. `pnpm build` → 3. 测试 → 4. `git add && git commit -m "..." && git push`

### 环境信息
- DB / 端口 / 容器名等

### 重要约束
- 大文件用 `skills/prototype-design/scripts/write-large-file.sh`
- 禁用 OpenClaw write 工具写 >10KB 文件
- set -euo pipefail
```

### type=deploy（部署任务）

```markdown
## 任务 TASK-YYYYMMDD-NNN：部署 <服务名> 到 <环境>

### 目标环境
- 服务器：<IP> / <SSH 别名>
- 端口：<port>
- 域名：<domain>
- 部署路径：<absolute path>

### 步骤
1. 拉代码 / 构建产物
2. 执行 `bash skills/deploy-app/scripts/<env>.sh <project>`
3. 验证：curl <url> 期望返回 200
4. 更新 DEPLOY-LOG.md + INFRA-LEDGER.md

### 回滚预案
<必填>
```

### type=test（测试任务）

```markdown
## 任务 TASK-YYYYMMDD-NNN：测试 <模块/功能>

### 测试范围
- 目标 URL / 接口列表（内联）
- 测试用例（内联，含输入输出）

### 期望
- 用例 1：<输入> → <输出>
- ...

### 报告位置
`docs-repos/<project>/test-reports/TASK-XXX.md`
```

### type=proto（原型任务）

```markdown
## 任务 TASK-YYYYMMDD-NNN：生成 <模块> 原型

### 风格
- wireframe / highfi / interactive

### 模块清单
- 模块 1：<功能描述>
- 模块 2：...

### 工具
- 必须用 `skills/prototype-design/scripts/generate.sh`
- 大文件用 write-large-file.sh
```

### type=infra（基础设施任务）

```markdown
## 任务 TASK-YYYYMMDD-NNN：<标题>

### 范围（明确写"不动什么"）
- ✅ 允许修改：<list>
- ❌ 禁止修改：<list>

### 必做测试
- <测试 1>
- <测试 2>

### 完成后必做
- 更新 INFRA-LEDGER.md
- git commit + push（如在 git 仓库内）
```

## 合规性校验逻辑（check-task-desc.sh）

打分制：

- 起始 100 分
- ❌ 出现"读取/参考/看一下" + 文件路径关键词 → -50（致命）
- ❌ 没有任何绝对路径 → -30
- ❌ 没有"commit/push/部署/build/test" → -20
- ⚠️ 估时 > 5 分钟 → -10
- ⚠️ 提到 HTML/MD/JSON 生成但没提 write-large-file.sh → -15

输出：
- ≥ 80 → ✅ 可派发
- 60-79 → ⚠️ 建议优化
- < 60 → ❌ 禁止派发

## 与现有 skill 的关系

- `requirement` 负责需求登记（REQ-）
- `prototype-design` 负责原型生成
- `deploy-app` 负责部署执行
- **`dispatch-task` 负责"主Agent 派子 Agent 之前的合规闸"**，与上述并列，不重叠
