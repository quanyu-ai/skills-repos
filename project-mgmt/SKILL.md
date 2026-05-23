---
name: project-mgmt
description: 项目全生命周期档案管理 skill。管理项目状态/里程碑/决策/事故/指标，提供跨项目仪表盘，串联 requirement / prototype-design / deploy-app。
metadata: {"openclaw":{"emoji":"📂","os":["linux"],"requires":{"bins":["jq"]}}}
user-invocable: true
---

# project-mgmt — 项目档案管理 Skill 📂

> 给"项目"建一份**长期档案**：基础信息 + 阶段状态 + 里程碑 + 决策记录 + 事故反馈 + 自动指标。
> 跨项目时一条命令出仪表盘，告别 PROJECT-BOARD.md 手工维护。
> 版本：Phase 1（纯文件 + jq 索引，无数据库）

---

## ⛔ 红线（违反 = 立即停手 + 在 MEMORY.md 补踩坑）

1. **禁止跳过编号**：项目 id 必须是 kebab-case（小写字母 + 数字 + `-`），与 `docs-repos/<id>/` 同名
2. **禁止散落记录**：决策 / 里程碑 / 事故 **必须**走对应脚本写到结构化文件，禁止零散塞到 README 或随手 echo
3. **禁止直接编辑 `_registry.json`**：维护必须通过 `new-project.sh` / `update-status.sh`，避免破坏索引

---

## 🚦 启动前自检

```bash
bash {{SKILL_DIR}}/scripts/doctor.sh
```

- 输出 `READY` → 进入正常流程
- 输出 `NEED_SETUP: <原因>` → **暂停操作**，按 `setup.md` 修复

`{{SKILL_DIR}}` = `/var/lib/openclaw/.openclaw/workspace/skills/project-mgmt/`
项目档案落地目录 = `/var/lib/openclaw/.openclaw/workspace/knowledge-repos/projects/<id>/`

---

## 🗂️ 档案目录结构

```
knowledge-repos/projects/
├── _registry.json                    # 全项目索引（自动维护，禁止手改）
├── <project-id>/
│   ├── profile.json                  # 基础信息 + 状态 + 指标
│   ├── milestones.md                 # 里程碑日志（追加）
│   ├── decisions.md                  # 决策记录（追加，可链接 ADR）
│   ├── incidents.md                  # 事故 / 客户反馈（追加）
│   └── metrics.json                  # 自动计算的指标快照
└── ...
```

---

## 🚥 生命周期 7 阶段（状态机）

```
planning → requirement → design → develop → test → live
                                                 ↓
                                            deprecated
```

合法转换：
- 顺序推进：`planning → requirement → design → develop → test → live`
- 任何状态 → `deprecated`
- `live → develop`（hotfix / v2 迭代回流）
- `planning → deprecated`（构思被砍）
- **其他跳转**：脚本会拒绝并提示，需用 `--force` 才能绕过（force 会在 milestones.md 留记录）

---

## 📋 使用场景

### 场景 1：新建项目档案
```bash
bash {{SKILL_DIR}}/scripts/new-project.sh <id> \
  --display-name "<中文名>" \
  --client "<客户>" \
  --stage <planning|requirement|design|develop|test|live|deprecated> \
  [--owner <name>] [--tech-stack "..."] [--priority high|medium|low] \
  [--docs-dir docs-repos/<id>] [--code-dir code-repos/<id>] \
  [--tags "tag1,tag2"]
```
- 校验 id 是 kebab-case + 不重复
- 在 `knowledge-repos/projects/<id>/` 创建 5 个档案文件
- 追加到 `_registry.json`

### 场景 2：更新生命周期阶段
```bash
bash {{SKILL_DIR}}/scripts/update-status.sh <id> <new-stage> [--reason "..."] [--force]
```
- 跑状态机校验
- 写 `profile.json` 的 `stage` + `updated_at`
- 追加一条到 `milestones.md`：`[YYYY-MM-DD] STAGE-CHANGE: old → new (reason)`

### 场景 3：追加里程碑
```bash
bash {{SKILL_DIR}}/scripts/add-milestone.sh <id> "<标题>" [--date YYYY-MM-DD]
```
- 自动编号 + 日期，追加到 `milestones.md`

### 场景 4：追加决策记录
```bash
bash {{SKILL_DIR}}/scripts/add-decision.sh <id> "<决策标题>" [--ref ADR-001] [--rationale "..."]
```
- 追加到 `decisions.md`，可选 `--ref` 链接到方案设计的 ADR

### 场景 5：追加事故 / 反馈
```bash
bash {{SKILL_DIR}}/scripts/add-incident.sh <id> "<标题>" [--type bug|feedback|inner|outage] [--severity P0|P1|P2]
```
- 追加到 `incidents.md`，标签可选

### 场景 6：同步指标
```bash
bash {{SKILL_DIR}}/scripts/sync-metrics.sh <id>
# 全部项目同步：
bash {{SKILL_DIR}}/scripts/sync-metrics.sh --all
```
- 读 `docs-repos/<id>/requirements/requirements-map.json` → 算需求总数 / 活跃数
- 读 `docs-repos/<id>/prototype/meta/requirements-map.json` → 算原型数
- 读 `knowledge-repos/management/DEPLOY-LOG.md` → 数 30 天内部署条数
- 读 `code-repos/<id>/` git log → 30 天 commit 数（如目录存在）
- 写到 `profile.json.metrics` + `metrics.json` 快照

### 场景 7：仪表盘
```bash
bash {{SKILL_DIR}}/scripts/dashboard.sh
# 输出 markdown 版（管道到文件）：
bash {{SKILL_DIR}}/scripts/dashboard.sh --markdown > /tmp/board.md
```
- 控制台彩色表格 + 末尾按阶段汇总

---

## 🔄 与其他系统的协同

| Skill | 用法 |
| --- | --- |
| `requirement` | `sync-metrics` 读 `requirements-map.json` 算需求数 / 活跃数 |
| `prototype-design` | `sync-metrics` 读 `prototype/meta/requirements-map.json` 算原型数 |
| `deploy-app` | `sync-metrics` 在 `DEPLOY-LOG.md` 里 grep 项目名数 30 天部署条数 |
| `solution-design` | `add-decision --ref ADR-XXX` 链接到方案 ADR |

> `PROJECT-BOARD.md` 不再纯手工维护 → 用 `dashboard.sh --markdown` 输出后人工挑选合并。

---

## 🧪 自检与排错
- 出问题先跑 `doctor.sh`，会同时校验：每个项目档案文件齐全 / `_registry.json` 一致 / `stage` 合法
- 大文件写入参考 `skills/prototype-design/scripts/write-large-file.sh`
- 编号 / 日期统一用 `Asia/Shanghai` 时区
