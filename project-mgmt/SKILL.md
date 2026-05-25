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
4. **决策 / 事故 / 里程碑必须主动登记，禁止后置反向迁移或关键字自动识别**：
   - 决策（decision）触发：技术选型 / 架构变更 / 工具替换 / 关键流程拍板 → 当场跑 `add-decision.sh`
   - 事故（incident）触发：线上故障 / 用户报错 / 部署失败 / 数据问题 → 当场跑 `add-incident.sh`
   - 里程碑（milestone）触发：阶段性交付 / 重要节点 / 客户验收 → 当场跑 `add-milestone.sh`
   - **不要事后用脚本从 README / PROJECT-BOARD / Git log 反向扫关键字**，关键字误判率高、上下文丢失、容易污染档案。`migrate-from-board.sh` 是历史一次性工具，已冻结，不再扩充关键字。
   - 跨项目 / 平台级 / 战略类用 `add-global-milestone.sh` 而不是塞到某个项目里。
5. **stage 变更 / 字段变更必须带 `--reason "..."`（≥5 字符）**：`update-status.sh` 切阶段、`set-field.sh` 改字段都强制要求理由，缺失或敷衍（如 `--reason a`）直接拒绝。`--force` 跳转更需要解释，reason 仍然必填。

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
│   ├── profile.json                  # 基础信息 + 状态 + metrics + roi + team_roles / risk_level / health
│   ├── milestones.md                 # 里程碑日志（追加，含 STAGE-CHANGE / FIELD-CHANGE）
│   ├── decisions.md                  # 决策记录（追加，可链接 ADR）
│   ├── incidents.md                  # 事故 / 客户反馈（追加）
│   ├── metrics.json                  # 自动计算的指标快照（状态视角）
│   └── roi.json                      # ROI 快照（效率视角：tasks/估时/实时/节约/commits/deploys + matched_task_ids）
└── ...
```

> profile.json 关键字段：
> - `team_roles`: `[{"name":"呆呆","role":"PM"}, ...]`（区别于旧的 `ai_team` 字符串数组）
> - `risk_level`: `low | medium | high | critical`（默认 `low`）
> - `health`: `green | yellow | red`（默认 `green`）
> - `metrics`: 状态快照（需求/原型/ADR/部署/commits 30d），由 `sync-metrics.sh` 写入
> - `roi`: 效率统计（tasks_total / tasks_completed / estimated_minutes / actual_minutes / saved_minutes / save_ratio / commits_count / deploys_count / last_calculated_at），由 `sync-roi.sh` 写入；与 metrics 并存，metrics 看现状、roi 看效率
> - 三者通过 `set-field.sh` 修改（强制 reason），不要手改 json。

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
bash {{SKILL_DIR}}/scripts/update-status.sh <id> <new-stage> --reason "..." [--force]
```
- 跑状态机校验
- **`--reason` 必填（≥5 字符）**，缺失或敷衍直接拒绝；`--force` 跳转更需要解释
- 写 `profile.json` 的 `stage` + `updated_at`
- 追加一条到 `milestones.md`：`[YYYY-MM-DD] STAGE-CHANGE: old → new (reason)`

### 场景 2.5：调整字段（risk / health / priority / next_milestone / tech_stack）
```bash
bash {{SKILL_DIR}}/scripts/set-field.sh <id> <field> <value> --reason "..."
# 例：
bash {{SKILL_DIR}}/scripts/set-field.sh smart-college health yellow --reason "原型 sidebar 未修，待开发盖茨修复"
bash {{SKILL_DIR}}/scripts/set-field.sh smart-college risk_level medium --reason "v4 116 条需求变化大"
```
- 合法 field 白名单：`risk_level | health | priority | next_milestone | tech_stack`
- 白名单**不含** id / stage / started_at / updated_at / metrics（这些由专属脚本或系统自动维护）
- 枚举字段会强校验取值（如 `health: green|yellow|red`）
- `--reason` 必填（≥5 字符），自动追加一条 `FIELD-CHANGE` 到 `milestones.md`
- 改 `priority` 时会同步更新 `_registry.json`

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

### 场景 8：主 Agent 启动上下文快查（重要）
```bash
bash {{SKILL_DIR}}/scripts/refresh-context.sh
```
- 读所有 `profile.json` + 里程碑 + 决策，输出到 `knowledge-repos/management/PROJECTS-CONTEXT.md`。
- **自动联动** `render-dashboard-html.sh`（场景 11）：每次跑 refresh-context 都会同时刷新 `dashboard.html`，无需手工。
- AGENTS.md 已引用 PROJECTS-CONTEXT.md，主 Agent 启动即看到。
- **何时跑**：`add-milestone` / `add-decision` / `add-incident` / `update-status` / `add-global-milestone` 已自动调一次，无需手动。批量场景请 `PROJECT_MGMT_AUTO_REFRESH=0` 跳过、结束后再手动刷一次。

### 场景 8.5：全局里程碑（无项目归属）
```bash
bash {{SKILL_DIR}}/scripts/add-global-milestone.sh "<title>" --category skill|infra|strategy|platform|process [--date YYYY-MM-DD]
```
- 适合：skill 升级 / 基建变更 / 公司战略 / 跨项目平台 / 流程改造。
- 写入 `knowledge-repos/management/GLOBAL-MILESTONES.md`，并自动 refresh PROJECTS-CONTEXT.md 末尾的「最近全局里程碑」节。
- 非法 category 直接 exit 1。

### 场景 10：项目 ROI 同步（sync-roi.sh）
```bash
bash {{SKILL_DIR}}/scripts/sync-roi.sh <project-id>
bash {{SKILL_DIR}}/scripts/sync-roi.sh <project-id> --since 2026-05-01
bash {{SKILL_DIR}}/scripts/sync-roi.sh --all
bash {{SKILL_DIR}}/scripts/sync-roi.sh --all --since 2026-05-22
```
- 数据源：`TASK-TRACKER.json`（按 id/display_name/tags 关键词匹配 title/description/tags）+ `git log`（docs-repos/<id>/ + code-repos/<id>/，兼容 monorepo 子目录 / 子项目独立 git）+ `DEPLOY-LOG.md`（grep id 或 display_name，默认 30d 内）
- 写两份：
  - `profile.json.roi.*` + `roi.last_calculated_at`
  - `roi.json`（独立快照：calculated_at / since / data_sources / 全部数值 / matched_task_ids 列表）
- `--all` 末尾输出 markdown 表格汇总到 stdout（不写文件），可直接拼接到 SKILLS-ROI-REPORT。
- 单项目 ≤ 5s，--all 8 项目 ≤ 30s。
- 输出示例：
```
✓ smart-college          tasks=10/11  est=208min  act=121min  saved=87min (42%)  commits=32  deploys=36
```
- 找不到 docs-repos/code-repos 目录 → commits_count=0，不报错；DEPLOY-LOG.md 缺失 → deploys_count=0。

### 场景 9：从老 PROJECT-BOARD.md 迁移历史（⚠️ 一次性历史工具）

> ⚠️ **一次性历史工具**，已冻结。不要扩充 decision/incident 关键字、不要把它当成日常入口。新事项请走 add-milestone / add-decision / add-incident / add-global-milestone。
```bash
bash {{SKILL_DIR}}/scripts/migrate-from-board.sh           # dry-run
bash {{SKILL_DIR}}/scripts/migrate-from-board.sh --apply   # 真写入
```
- 按关键字把看板里的历史里程碑 / 状态 / 决策映射到对应项目档案。
- 默认 dry-run；看完报告再 --apply。

### 场景 11：HTML Dashboard（可视化仪表盘）

```bash
bash {{SKILL_DIR}}/scripts/render-dashboard-html.sh
bash {{SKILL_DIR}}/scripts/render-dashboard-html.sh --output /tmp/my-dashboard.html
```

- 生成**单文件零依赖**的 `knowledge-repos/management/dashboard.html`，浏览器可离线打开。
- 内容：顶栏渐变 header + 6 个全局 KPI 卡 + N 个项目卡片（阶段徽章 / 健康 / 风险 / ROI / next milestone / 团队 / mini timeline / docs·code 链接）+ 底部全局里程碑 tail 10。
- **响应式**：手机 / 平板 / PC 均可阅读，内嵌单条下拉「按阶段筛选」（vanilla JS）。
- **自动联动**：场景 8 `refresh-context.sh` 跳完会自动调一次，任何 `add-milestone` / `update-status` / `set-field` / `add-global-milestone` 都会同步刷新 dashboard。
- 约束：输出 ≤ 100KB / 生成 ≤ 10s / 纯 bash + jq 拼接（不引外部 CSS·JS·字体）。

---

## 🔄 与其他系统的协同

| Skill | 用法 |
| --- | --- |
| `requirement` | `sync-metrics` 读 `requirements-map.json` 算需求数 / 活跃数 |
| `prototype-design` | `sync-metrics` 读 `prototype/meta/requirements-map.json` 算原型数 |
| `deploy-app` | `sync-metrics` 在 `DEPLOY-LOG.md` 里 grep 项目名数 30 天部署条数 |
| `solution-design` | `add-decision --ref ADR-XXX` 链接到方案 ADR |
| `SKILLS-ROI-REPORT` | `sync-roi.sh --all` 末尾的 markdown 表格可直接拼接到全局 ROI 报告里，作为「按项目维度」补充章节 |

> `PROJECT-BOARD.md` 已归档（2026-05-24）→ 新的项目快查入口是 `knowledge-repos/management/PROJECTS-CONTEXT.md`（由 `refresh-context.sh` 生成）。

---

## 🧪 自检与排错
- 出问题先跑 `doctor.sh`，会同时校验：每个项目档案文件齐全 / `_registry.json` 一致 / `stage` 合法
- 大文件写入参考 `scripts/write-large-file.sh`
- 编号 / 日期统一用 `Asia/Shanghai` 时区
