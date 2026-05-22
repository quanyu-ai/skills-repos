# requirement — 需求管理 Skill 📋

> 把"需求"做成可拆分、可追踪、可索引的标准条目。
> 所有项目需求统一落到 `docs-repos/<project>/requirements/REQ-YYYYMMDD-NNN.md`，由 `requirements-map.json` 反查索引。

---

## 项目简介

requirement 是 OpenClaw 的标准化需求管理 Skill，旨在解决：

1. **需求散在群里/口头里** → 无法追踪、无法索引、无法生成原型
2. **没有统一编号** → 跨人协作时找不到"上次说的那个需求"
3. **状态不清** → 不知道哪些是 draft、哪些 approved、哪些已实现
4. **需求-原型-代码-测试 断链** → 改了需求不知道影响哪些文件

---

## 设计理念

### 三大原则

1. **一条需求 = 一个 .md 文件**：天然支持版本控制、Diff、Review
2. **编号即身份**：`REQ-YYYYMMDD-NNN` 唯一不可变，跨人/跨 skill 引用就靠它
3. **索引自动化**：`requirements-map.json` 由 `sync-map.sh` 维护，永远是 .md 的镜像，绝不手改

### 状态机

```
   draft ──reviewing── approved ──implementing── done
                              │
                              └──── deprecated
```

| 状态 | 含义 |
|------|------|
| `draft` | 刚拆出来，尚未评审 |
| `reviewing` | 评审中，可能被打回 |
| `approved` | 已评审通过，进入待开发池 |
| `implementing` | 开发中，对应 TASK-TRACKER 应有任务 |
| `done` | 上线验收通过 |
| `deprecated` | 弃用（被新 REQ 取代或不再做） |

---

## 能力清单

| 能力 | 脚本 | 状态 |
|------|------|------|
| 自检 | `doctor.sh` | ✅ Phase 1 |
| 新建需求 | `new-req.sh` | ✅ Phase 1 |
| 列表查询 | `list-req.sh` | ✅ Phase 1 |
| 同步索引 | `sync-map.sh` | ✅ Phase 1 |
| docx 导入 | `import-doc.sh` | ✅ Phase 1（仅解析+大纲） |
| 状态流转 | `promote-req.sh` | ⏳ Phase 2 |
| frontmatter 校验 | `lint-req.sh` | ⏳ Phase 2 |
| 跨项目搜索 | `search-req.sh` | ⏳ Phase 4 |

---

## 目录结构

```
skills/requirement/
├── SKILL.md                       # 触发入口 + 红线
├── README.md                      # 本文档
├── setup.md                       # 首次使用引导
├── scripts/
│   ├── doctor.sh                  # 自检
│   ├── new-req.sh                 # 创建一条需求
│   ├── list-req.sh                # 列出需求
│   ├── sync-map.sh                # 同步 requirements-map.json + INDEX.md
│   └── import-doc.sh              # 从 docx 解析/导入
├── templates/
│   ├── req-template.md            # 单条需求模板
│   └── requirements-map.template.json
└── config/
    └── schema.md                  # 字段规范
```

---

## 快速开始

### 1. 自检

```bash
bash skills/requirement/scripts/doctor.sh
```

### 2. 创建一条需求

```bash
bash skills/requirement/scripts/new-req.sh smart-college "学院领导-工作台" \
    --role 学院领导 --phase 一阶段 --priority P0
```

输出形如：
```
✓ Created: docs-repos/smart-college/requirements/REQ-20260522-003.md
```

### 3. 同步索引

```bash
bash skills/requirement/scripts/sync-map.sh smart-college
```

### 4. 查看列表

```bash
bash skills/requirement/scripts/list-req.sh smart-college --status draft
```

### 5. 从需求说明书导入（仅大纲）

```bash
bash skills/requirement/scripts/import-doc.sh smart-college \
    docs-repos/smart-college/requirements/学院数字化管理平台业务需求说明书V3.0.docx
```

输出 docx 章节大纲，便于人工/Agent 决定如何拆分。

---

## 数据流

```
        ┌─────────────────────────────────────────┐
        │  docs-repos/<project>/requirements/      │
        │                                          │
        │  REQ-20260522-001.md  ──┐                │
        │  REQ-20260522-002.md  ──┤                │
        │  REQ-20260522-003.md  ──┤  sync-map.sh   │
        │       ...             ──┘       ▼        │
        │                                          │
        │  requirements-map.json  (机读索引)        │
        │  INDEX.md               (人读总览)        │
        └──────────────────┬───────────────────────┘
                           │
            ┌──────────────┼──────────────┐
            ▼              ▼              ▼
        原型设计 skill   开发 skill     测试 skill
        （读 map）       （读 map）     （读 map）
```

---

## 字段 schema 摘要

完整见 `config/schema.md`。

```yaml
---
id: REQ-20260522-001
title: 学院领导-工作台
status: draft           # draft|reviewing|approved|implementing|done|deprecated
phase: 一阶段           # 一阶段|二阶段|unscheduled
priority: P0            # P0|P1|P2
category: 业务功能      # 业务功能|数据需求|非功能需求
role: 学院领导
source_doc: 学院数字化管理平台业务需求说明书V3.0.docx
source_section: 6.1.1
created: 2026-05-22
updated: 2026-05-22
depends_on: []
related_files:
  prototype: []
  design: []
  code: []
  test: []
---
```

---

## 与其他系统的关系

| 系统 | 关系 |
|------|------|
| `knowledge-repos/management/TASK-TRACKER.json` | `status=implementing` 的需求必须挂一个 task |
| 原型设计 skill（未来） | 按 REQ 生成 HTML/Figma 原型，回写 `related_files.prototype` |
| 开发 skill | 实现时把代码路径写入 `related_files.code` |
| 测试 skill | 按 `acceptance_criteria` 生成用例 |

---

## 维护人

- 主要：龙哥（邓云龙）
- AI 调度：呆呆
- 文档：本 README + setup.md + config/schema.md

---

## Phase 路线图

| 阶段 | 状态 | 功能 |
|------|------|------|
| **Phase 1** | ✅ 当前 | 框架 + 自检 + 模板 + new/list/sync/import |
| **Phase 2** | ⏳ | 状态流转脚本 + frontmatter 校验 |
| **Phase 3** | ⏳ | 与原型设计 skill 联动 |
| **Phase 4** | ⏳ | 跨项目搜索 + 全局 dashboard |

---

## 📦 版本归档机制（v2 新增）

### 何时归档？

| 触发场景 | 归档 | 备注 |
|---------|------|------|
| 接收新需求文档（客户新版 docx） | ✅ 强制 | 用 `archive.sh` 先备份现状再 import |
| 客户验收某版本（v1.0 / v3.0 等） | ✅ 强制 | 用 `promote.sh` 打版本号 |
| 重大需求重排（>30% REQ 变动） | ✅ 推荐 | 用 `archive.sh` 备份 |
| 单条/少量 REQ 修改 | ❌ 不归档 | 只在 CHANGELOG.md 记一条 |
| 仅状态字段变更（draft→ready） | ❌ 不归档 | 只在 REQ history 加一条 |

### 归档目录命名规范

```
docs-repos/<project>/requirements/_archive/<版本号>-<日期>/
                                          └─ 例：v3.0-20260522/
                                          └─ 例：v1.0-20260515-客户原始/  (可加后缀)
```

### 版本号语义（语义化版本）

```
主版本.次版本.补丁  例：v3.2.1
│    │     └─ 补丁：拼写/小调整，REQ 数量不变
│    └────── 次版本：新增模块/页面，REQ 数量增加
└─────────── 主版本：客户大改版/重新签约/平台重构
```

特殊版本号：
- `v1.0-客户原始` —— 客户首次给的原始文档归档
- `v2.0-内部消化` —— 我方内部消化整理后版本
- `v3.0-需求说明书` —— 正式输出给客户的需求说明书版本

### 三个核心脚本

```bash
# 1. 归档当前需求快照
bash skills/requirement/scripts/archive.sh <project> <version> [--source-doc <docx>]

# 2. 比较两个版本差异
bash skills/requirement/scripts/diff-version.sh <project> <v1> <v2>
# v1/v2 可以是 'v3.0' / 'v3.0-20260522' / 'current'

# 3. 升级为正式版本（归档 + 更新 frontmatter + 加 history）
bash skills/requirement/scripts/promote.sh <project> <new-version>
```

### 不归档的轻量记录

| 变更类型 | 记录位置 |
|---------|---------|
| 状态流转 | REQ-*.md 的 `history` 字段 |
| 单条修改 | CHANGELOG.md 加一行 |
| 子任务派发 | TASK-TRACKER.json |

### CHANGELOG.md 位置

`docs-repos/<project>/requirements/CHANGELOG.md`

每次 archive/promote 会自动在顶部 prepend 一条记录。
