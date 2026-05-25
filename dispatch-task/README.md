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
- 大文件用 `scripts/write-large-file.sh`
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

---

## 🆕 补充：合规打分规则详解

`check-task-desc.sh` 内置的打分制，是把"派单是否合规"量化的最后一道闸。

### 评分表（起始 100 分）

| 项 | 等级 | 扣分 | 说明 |
|----|------|-----|------|
| 出现"读取/参考/看一下" + 文件路径关键词 | ❌ 致命 | -50 | 主 Agent 自己读，等于不派 |
| 没有任何绝对路径 | ❌ 致命 | -30 | 子 Agent 无法定位工作目录 |
| 没有 commit/push/部署/build/test 任一关键词 | ❌ 致命 | -20 | 没有可交付物，不闭环 |
| 估时 > 5 分钟 | ⚠️ 警告 | -10 | 单任务过大，建议拆分 |
| 提到 HTML/MD/JSON 生成但没提 write-large-file.sh | ⚠️ 警告 | -15 | 易触发 OpenClaw write 工具的隐式截断 |

### 阈值判定

| 分数区间 | 判定 | 行动 |
|---------|------|------|
| ≥ 80 | ✅ 可派发 | 直接 `sessions_spawn` |
| 60-79 | ⚠️ 建议优化 | 龙哥同意可派，否则改 |
| < 60 | ❌ 禁止派发 | 必须改完再跑 |

### 配合 `pre-dispatch.sh` 使用

```bash
bash scripts/pre-dispatch.sh <task-file>
# 内部会依次调用：
#   1. check-task-desc.sh（合规打分）
#   2. 工作区状态扫描（是否有未提交变更）
#   3. AGENTS.md 5 铁律自检提示
```

---

## 与 AGENTS.md 5 铁律的对应关系

主 Agent 的 5 条铁律，每一条在派单阶段都有对应保障：

| 铁律 | 对应保障 |
|------|---------|
| 1️⃣ 不直接写业务代码 | 派单时强制带"目标项目目录" + commit 关键词 |
| 2️⃣ 不直接执行构建 | 派单描述里 build/test 关键词由子 Agent 执行 |
| 3️⃣ 不直接执行部署 | deploy / docker / pm2 类操作必须派 |
| 4️⃣ 不使用 `sessions_yield` | 派单模板顶部固定写 `❌ 不 sessions_yield` |
| 5️⃣ 完成必更 TASK-TRACKER | 派单"完成后"块固定要求更新 tracker + push |

`dispatch-template.sh` 生成的模板已经默认带齐这些保障字段，不要手撸派单。

---

## 派单实战：反例 vs 正例（来自今日 23 个 TASK）

### ❌ 反例 1：让子 Agent "读取"

```
请读取 /var/lib/openclaw/.openclaw/workspace/skills/requirement/SKILL.md
然后帮我把 set-status.sh 加上 --merged-to 参数支持。
```

**问题：** "读取 SKILL.md" 这步主 Agent 自己干就行，不该派；子 Agent 启动费 token 又费时间。
**评分：** 100 - 50（致命）= 50 → ❌ 禁止派发

**正例：**
```
## 任务：在 set-status.sh 增加 --merged-to 参数
工作目录：/var/lib/openclaw/.openclaw/workspace/skills/requirement/scripts/
约束：deprecated 时必须二选一（--merged-to 或 --reason），否则 exit 2
完成后：git commit && push；更新 TASK-TRACKER.json TASK-XXX → completed
预估：3 分钟
```

### ❌ 反例 2：没有绝对路径

```
帮我把原型门户页生成器写好，并部署上去。
```

**问题：** 没说哪个项目、没绝对路径、没 build/deploy 细节。
**评分：** 100 - 30 - 20 = 50 → ❌ 禁止派发

### ✅ 正例：今日 TASK-20260523-023（generate-index.sh）

完整任务描述包含：
- 工作目录绝对路径
- 输入文件清单 + 是否必需
- 输出文件路径 + Assertion（>8KB / 含版本切换器 / 至少 1 个角色块）
- 大文件写入用 `write-large-file.sh`
- 完成后：commit/push + 更新 TASK-TRACKER + 提交报告

**评分：** 100 分 → ✅ 直接派发，子 Agent 26 分钟交付。

### ✅ 正例：今日 TASK-20260523-018（lint.sh + gen-changes.sh）

- 双脚本一次性派
- 每个脚本规定了入参/退出码/输出位置
- 明确"放进 skills/ 不动 docs-repos"边界

**评分：** 100 分 → ✅ 高效产出。

---

## 派发前的"3 看 1 跑"

派单前的最后 30 秒检查：

1. 👀 **看路径**：所有路径都是绝对路径吗？
2. 👀 **看动作**：有 commit/push/build/test/deploy 任一闭环动词吗？
3. 👀 **看大文件**：要生成 HTML/MD/JSON 吗？有没有提 `write-large-file.sh`？
4. 🏃 **跑校验**：`bash scripts/pre-dispatch.sh <task-file>`，分数 ≥ 80 才发车。

记住：派单的质量决定子 Agent 的质量。**不要把"派单"这件事本身派出去**——这是主 Agent 的责任。

