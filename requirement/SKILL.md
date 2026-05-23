---
name: requirement
description: 需求管理 skill，规范化创建/查询/状态跟踪需求条目，按 REQ-YYYYMMDD-NNN 格式管理，支持从 docx 导入，自动维护需求-原型-代码映射表。
metadata: {"openclaw":{"emoji":"📋","os":["linux"],"requires":{"bins":["jq","pandoc"]}}}
user-invocable: true
---

# requirement — 需求管理 Skill 📋

> 把"需求"做成一个可拆分、可追踪、可索引的标准条目。
> 项目经理（小呆呆 / 龙哥）不再把需求散在脑子或大段聊天里，所有需求必须落到 `REQ-YYYYMMDD-NNN.md` 条目。
> 版本：Phase 1 框架（纯文件 + jq 索引，无数据库）

---

## 🚦 启动前自检（每次调用本 skill 第一步）

```bash
bash {{SKILL_DIR}}/scripts/doctor.sh
```

- 输出 `READY` → 进入正常流程
- 输出 `NEED_SETUP: <原因>` → **暂停操作**，先按 `setup.md` 引导完成初始化

`{{SKILL_DIR}}` 解析：本 skill 的根目录是
`/var/lib/openclaw/.openclaw/workspace/skills/requirement/`。

---

## 📋 使用场景

### 场景 1：创建一条新需求

```bash
bash {{SKILL_DIR}}/scripts/new-req.sh <project> "<title>" [--role <role>] [--phase <一阶段|二阶段>] [--priority P0|P1|P2]
```

- `<project>`：项目目录名（如 `smart-college`、`chenxi-study`），对应 `docs-repos/<project>/requirements/`
- `<title>`：需求标题，建议格式 `<角色>-<功能名>`
- 自动分配 `REQ-YYYYMMDD-NNN` 编号（YYYYMMDD = 当天，NNN 自增）
- 自动用 `templates/req-template.md` 生成条目并落到 `docs-repos/<project>/requirements/REQ-<id>.md`

### 场景 2：列出某项目的所有需求

```bash
bash {{SKILL_DIR}}/scripts/list-req.sh <project> [--status <状态>] [--phase <阶段>] [--role <角色>]
```

输出表格：`id | title | status | phase | priority | role`

### 场景 3：同步索引表

```bash
bash {{SKILL_DIR}}/scripts/sync-map.sh <project>
```

扫描 `docs-repos/<project>/requirements/REQ-*.md`，自动维护
`docs-repos/<project>/requirements/requirements-map.json`：
- 解析每条 REQ 的 frontmatter
- 索引 `id → {title, status, phase, priority, role, related_files, source_section}`
- 用于后续被原型设计/开发/测试 skill 反查

### 场景 4：从 docx 导入需求

```bash
bash {{SKILL_DIR}}/scripts/import-doc.sh <project> <docx_path> [--auto-split]
```

- 用 `pandoc` 把 docx 解析成 markdown
- `--auto-split` 时按章节自动拆分（适用于需求说明书）
- 默认仅打印章节大纲，由人工/Agent 决定如何拆分

### 场景 5：状态流转

```bash
bash {{SKILL_DIR}}/scripts/set-status.sh <project> <REQ-id> <new-status>
bash {{SKILL_DIR}}/scripts/set-status.sh <project> --role <角色> <new-status>
bash {{SKILL_DIR}}/scripts/set-status.sh <project> --phase <阶段> <new-status>
bash {{SKILL_DIR}}/scripts/set-status.sh <project> --all <new-status>

# 转 deprecated 时必须二选一：--merged-to <REQ-ID>  或  --reason "<原因>"
bash {{SKILL_DIR}}/scripts/set-status.sh <project> REQ-XXXX-001 deprecated --merged-to REQ-XXXX-099
bash {{SKILL_DIR}}/scripts/set-status.sh <project> REQ-XXXX-002 deprecated --reason "客户撤回"
```

需求状态机（脚本会强制校验，非法转换会失败回滚）：

```
draft → reviewing → approved → implementing → done
     ↘            ↘                          ↘ deprecated
        draft（打回）
```

- 任何状态 → `deprecated` 允许（但必须填 `merged_to` 或 `--reason`）
- 相同状态 → 相同状态会被自动跳过（幂等）
- 批量模式先 dry-run 校验全部，任一失败则整批回滚
- 脚本自动追加 `history` 条目、更新 `updated`、调用 `sync-map.sh` 重建索引、跑 post-check assertion

### 场景 6：生成版本变更对照表（v3 → v4 场景）

```bash
bash {{SKILL_DIR}}/scripts/gen-changes.sh <project> <from-version> <to-version>
# 例：bash gen-changes.sh smart-college v3.0 v4.0
```

- 对比 `_archive/<from>-*/requirements-map.json` 与当前 `requirements-map.json`
- 输出 `reviews/CHANGES-<from>-to-<to>.md`：包含总览 + 逐条变更表（deprecated/added/modified/unchanged）
- 废弃项会读 REQ 文件的 `merged_to` / `deprecated_reason`，自动填备注
- 前提：已用 `archive.sh` 归档旧版本

### 场景 7：Lint 需求质量

```bash
bash {{SKILL_DIR}}/scripts/lint.sh <project>
# 退出码 0=全部通过，1=有错误
```

检查项：
- 必填字段：`id / title / status / phase / priority / category / created / updated`
- `id` 格式必须为 `REQ-YYYYMMDD-NNN`
- `status` 必须在状态机集合内
- 文件名 ≡ `id` 字段
- `status: deprecated` 必须有 `merged_to` 或 `deprecated_reason` 或 history.reason
- `updated >= created`

适用场景：CI/PR 门禁、大改后全量托底检查。


---

## ⛔ 红线（违反 = 任务失败）

1. ⛔ **禁止跳过编号规则**：所有需求必须用 `REQ-YYYYMMDD-NNN` 格式
2. ⛔ **禁止把需求散文写在群里就算完成**：必须落到 `.md` 条目
3. ⛔ **禁止改动他人已 approved 的需求**：要变更必须新建 REQ 并标 `depends_on`
4. ⛔ **禁止越权写入项目代码**：本 skill 只维护 `docs-repos/**` 下的 `.md/.json`
5. ⛔ **禁止 0 编号**：`NNN` 从 `001` 起，不允许 `000`
6. ⛔ **禁止手工 sed / 直接编辑 frontmatter 改 status**：必须通过 `scripts/set-status.sh`（脚本会校验状态机、写 history、重建索引并跑 post-check）

---

## 📂 文件位置约定

```
docs-repos/<project>/
└── requirements/
    ├── REQ-20260522-001.md     # 一条需求 = 一个 .md
    ├── REQ-20260522-002.md
    ├── ...
    ├── requirements-map.json   # 由 sync-map.sh 维护
    └── INDEX.md                # 由 sync-map.sh 维护的人读索引
```

---

## 📦 需求条目字段（frontmatter）

| 字段 | 必填 | 说明 |
|------|------|------|
| `id` | ✅ | `REQ-YYYYMMDD-NNN` |
| `title` | ✅ | 一句话标题（建议 `<角色>-<功能名>`） |
| `status` | ✅ | `draft` / `reviewing` / `approved` / `implementing` / `done` / `deprecated` |
| `phase` | ✅ | `一阶段` / `二阶段` / `unscheduled` |
| `priority` | ✅ | `P0` / `P1` / `P2` |
| `category` | ✅ | `业务功能` / `数据需求` / `非功能需求` |
| `role` | 否 | 角色名（如 `学院领导`） |
| `source_doc` | 否 | 来源文档文件名 |
| `source_section` | 否 | 来源章节号 |
| `created` | ✅ | `YYYY-MM-DD` |
| `updated` | ✅ | `YYYY-MM-DD` |
| `depends_on` | 否 | `[REQ-id, ...]` |
| `related_files` | 否 | `{prototype: [], design: [], code: [], test: []}` |

完整 schema 见 `config/schema.md`。

---

## 🔄 与其他系统的关系

| 系统 | 关系 |
|------|------|
| `knowledge-repos/management/TASK-TRACKER.json` | 实施时 `status=implementing` 的 REQ 必须有对应 task |
| 原型设计 skill（未来） | 读取 `requirements-map.json`，按 REQ 生成 wireframe |
| 开发 skill | 读取 `related_files.code`，按 REQ 关联代码 |
| 测试 skill | 读取 `acceptance_criteria` 生成测试用例 |

---

## 🔗 详细文档

- 首次安装引导：`setup.md`
- 完整设计：`README.md`
- 字段 schema：`config/schema.md`
- 模板：`templates/req-template.md`

---

## 📌 Phase 路线

- **Phase 1（当前）**：框架 + 自检 + 模板 + new/list/sync/import 脚本
- **Phase 2**：状态流转脚本（`promote-req.sh`）+ 校验脚本（lint frontmatter）
- **Phase 3**：与原型设计 skill 联动，自动注入 `related_files.prototype`
- **Phase 4**：跨项目搜索 + 全局 dashboard
