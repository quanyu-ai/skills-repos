# task-template.md - 标准派单模板（防呆版 2026-05-24）

> 推荐用法：复制本文件 → 替换占位符 → 跑 `bash scripts/safe-dispatch.sh <文件>` 校验 → 通过后再 sessions_spawn
> 速查脚本输出 5 种类型：`bash skills/dispatch-task/scripts/dispatch-template.sh {dev|deploy|test|proto|infra}`

---

## 任务 TASK-YYYYMMDD-NNN：<标题>

### 工作目录
`/var/lib/openclaw/.openclaw/workspace/<相对路径>`（必须绝对路径）

### 任务概述
<明确目标，至少 3-5 行；说清「做什么」「为什么」「在哪做」>

### 当前状态（必要时内联）
- 关键文件：`<绝对路径>`
- 关键片段：粘贴最关键的 10-30 行代码 / 表结构 / 配置

### 目标产出
- 📄 文件清单：列出预期会创建/修改的文件路径
- 🔢 预期规模：N 行 / NkB
- 📌 提交方式：commit + push 到 `<repo>` 主分支

### 完整执行链路（步骤化）
1. 编辑 / 创建文件
2. 本地构建：`<cmd>` 期望 <result>
3. 验证：`<curl / pnpm test / playwright>` 期望 200/PASS
4. `git add . && git commit -m "feat: ..." && git push`
5. 更新台账（如适用）：DEPLOY-LOG.md / INFRA-LEDGER.md

### 环境信息
- 数据库：<连接串>
- 端口：<port>
- 容器/服务：<name>

### 重要约束
- ✅ 大文件 (>10KB) 用 `scripts/write-large-file.sh` 或 exec heredoc
- ✅ 所有 shell 脚本 `set -euo pipefail`
- ❌ 禁用 OpenClaw `write` 工具写 >10KB 文件（会被静默截断，踩坑见 MEMORY.md 2026-05-23）
- ❌ 不 `sessions_yield`（会挂起子 Agent）
- ❌ 不直接修改本任务范围外的文件

---

## ⛔ 反"以思考代替行动"约束（必读）

### 不允许的行为
- ❌ 只规划/讨论方案，不实际执行
- ❌ 完成报告里没有真实产出路径
- ❌ 用"已设计完成 / 已规划完成 / 思路明确"等模糊表达替代"已写入文件并 push"

### 必做自检（完成前 / 100% 不许偷懒）
```bash
# 1. 列出所有声称已创建的文件（必须 ls 出来）
ls -la <expected-path-1> <expected-path-2> ...

# 2. 看 git status（待 commit 的文件）
cd <repo> && git status --short

# 3. 看实际 commit + push 结果
git log --oneline -3
git rev-parse HEAD
git push origin <branch>
```

### 完成报告必含
- 📄 实际产出文件清单（**直接贴 `ls -la` 输出**，不要只说"已创建"）
- 🔢 行数 / 大小（**贴 `wc -l <file>` + `du -h <file>` 输出**）
- 📌 commit hash + push 状态（**贴 `git log --oneline -3` 输出**）
- ✅ 如有验证（构建/测试/启动），贴关键 stdout
- ❌ 如有遗漏 / 未完成 / 偏差，明确说明，**不要藏起来**

---

## 完成后必报回的内容（一个都不能少）
1. 实际改动文件清单 + ls 输出
2. wc -l / du -h 数据
3. git commit hash + push 状态
4. 关键验证命令的 stdout（curl / pnpm test 等）
5. 遇到的偏差 / 未完成项

预估 <N> 分钟。
