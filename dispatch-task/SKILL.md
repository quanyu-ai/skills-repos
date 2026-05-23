---
name: dispatch-task
description: 主Agent派发子任务的规范化流程，包含派发前必检、任务描述模板、合规性校验。适用于通过 sessions_spawn 创建子 Agent 之前的最后一道闸。
metadata: {"openclaw":{"emoji":"📋"}}
---

# dispatch-task - 子任务派发规范 📋

> 主Agent（呆呆）准备 `sessions_spawn` 派子 Agent 之前的最后一道闸。
> 配套脚本均位于 `scripts/`，从 SKILL 所在目录解析。

## 🎯 触发场景

- 主Agent 准备调 `sessions_spawn` 创建 detached / 一次性子 Agent
- 主Agent 准备把一个"读大文件→改代码→build→部署"的复合任务外包
- 任何"我想自己写但应该派出去"的犹豫时刻

## ⛔ 三条红线（违反任一不得派发）

1. ⛔ **不允许"读取/参考大文件"指令**
   - 反例："请查看 schema.prisma 然后写一个 seed 脚本"
   - 正例：主Agent 先读完，把要点（表结构、连接串、示例数据）**内联**到任务描述
2. ⛔ **不允许"凭感觉写"，必须内联具体路径/代码**
   - 文件必须给绝对路径
   - 修改必须给"当前代码 → 目标代码"
   - 部署必须给目标环境、端口、域名
3. ⛔ **必须先登记 `knowledge-repos/management/TASK-TRACKER.json` 再 spawn**
   - 任务 ID：`TASK-YYYYMMDD-NNN`
   - 字段：id / title / type / agent / status=dispatched / estimatedMinutes / timeoutSeconds / createdAt / requester / description

## 🧰 工具

| 命令 | 作用 |
| --- | --- |
| `bash scripts/check-task-desc.sh <file>` | 任务描述合规性校验（grep 违规词、检查绝对路径、检查 commit 链路），输出 ✅/⚠️/❌ 三档 |
| `bash scripts/pre-dispatch.sh <file>` | 派发前 5 项必检（任务描述 + TASK-TRACKER 登记 + 大文件提示等） |
| `bash scripts/dispatch-template.sh <type>` | 打印标准派单模板（type=dev/deploy/test/proto/infra） |

## 📋 任务描述必须包含

- ✅ 具体修改的文件**绝对路径**
- ✅ 修改方式（当前代码 → 目标代码 / 新增内容片段）
- ✅ 修改后的操作（build / 部署 / 测试 / commit / push）
- ✅ 环境信息（数据库连接、端口、路径、容器名）
- ✅ 单任务执行预估 ≤ 3 分钟；超时 ≤ 600s
- ✅ 若涉及生成 >10KB 文件，必须明示：使用 `skills/prototype-design/scripts/write-large-file.sh` 或 exec heredoc，**禁用 OpenClaw write 工具**（踩坑见 MEMORY.md 2026-05-23）

## 🚦 派发流程（标准 5 步）

1. 写任务描述到临时文件 `/tmp/task-$ID.md`
2. `bash scripts/check-task-desc.sh /tmp/task-$ID.md` 必须 ✅ 或仅 ⚠️
3. 在 `TASK-TRACKER.json` 增加条目，status=`dispatched`
4. `sessions_spawn` 派发，设置 `runTimeoutSeconds`
5. 等推送回收 → 更新 TASK-TRACKER → 必要时更新 DEPLOY-LOG / INFRA-LEDGER

## 🚨 常见违规模式（自动拦截）

| 模式 | 校验位置 |
| --- | --- |
| 出现"读取" / "参考" / "看一下" + 文件路径 | check-task-desc.sh |
| 没有任何绝对路径 (/var/...) | check-task-desc.sh |
| 没有"commit" / "push" / "部署" 关键词 | check-task-desc.sh |
| 产出大文件却没提 write-large-file.sh | check-task-desc.sh |

## 📚 详细设计 & 模板示例

见 `README.md`。
