---
name: solution-design
description: 项目方案设计 skill。统一架构/数据库/API/模块拆分文档结构 + ADR 决策记录 + 与 requirement/prototype-design 联动。
metadata: {"openclaw":{"emoji":"🏗️","os":["linux"]}}
user-invocable: true
---

# solution-design — 方案设计 Skill 🏗️

> 把"方案设计"做成标准化、可索引、可演进的多文件工程。
> 一个项目 = 一个 `docs-repos/<project>/solution/` 目录。
> 架构、数据库、API、模块拆分、ADR 决策记录，全部按统一目录布局落地，避免散乱命名。
> 版本：**Phase 1 轻量骨架**（只做模板 + init，复杂自动化留待 Phase 2+）

---

## 🚦 启动前自检（每次调用本 skill 第一步）

```bash
bash {{SKILL_DIR}}/scripts/doctor.sh
```

- 输出 `READY` → 进入正常流程
- 输出 `NEED_SETUP: <原因>` → **暂停操作**，按 `setup.md` 补齐

`{{SKILL_DIR}}` = `/var/lib/openclaw/.openclaw/workspace/skills/solution-design/`

---

## ⛔ 红线（绝对禁止）

1. **禁止跳过 ADR**：任何"为什么这么选"的技术决策必须新增一条 ADR 留档（即使一句话）
2. **禁止散乱命名**：方案文档必须放进 `docs-repos/<project>/solution/` 标准目录，不许散落到项目根目录
3. **禁止与 REQ 脱节**：每个 `modules/<name>/` 必须有 `reqs.json`，列出关联的 REQ-ID
4. **禁止覆盖现有 solution/**：`init-solution.sh` 检测到目录存在直接 exit 1，绝不静默覆盖
5. **禁止主 Agent 手写大段方案文档**：派子 Agent 来填充，方案 skill 只负责"骨架 + 模板"

---

## 📋 标准使用场景

### 场景 1：项目首次初始化方案目录

```bash
bash {{SKILL_DIR}}/scripts/init-solution.sh <project>
# 例：bash scripts/init-solution.sh smart-college
```

效果：在 `docs-repos/<project>/solution/` 生成完整骨架（架构 / 数据库 / API / 模块示例 / ADR / meta）。

### 场景 2：手工编辑方案文档

按目录结构在对应 `.md` 里填内容。模板已含必要章节占位（mermaid 图、表格等）。

### 场景 3：新增一条 ADR 决策记录

```bash
NEXT=$(ls docs-repos/<project>/solution/adr/ADR-*.md 2>/dev/null | wc -l)
NEXT=$(printf "%03d" $((NEXT + 1)))
cp {{SKILL_DIR}}/templates/adr-template.md docs-repos/<project>/solution/adr/ADR-${NEXT}-<short-title>.md
# 然后编辑该文件填入：背景 / 决策 / 备选方案 / 理由 / 影响
```

### 场景 4：新增一个模块设计

```bash
cp -r docs-repos/<project>/solution/modules/_example docs-repos/<project>/solution/modules/<module-name>
# 然后编辑 design.md / reqs.json / apis.json
```

---

## 🧩 与其他 skill 的联动

| 上游 / 下游 | 关系 |
| --- | --- |
| `requirement` | 模块的 `reqs.json` 引用 REQ-ID，方案设计必须基于已确认需求 |
| `prototype-design` | 方案模块可关联原型页面（Phase 2 引入显式索引） |
| `dispatch-task` | 复杂模块设计派子 Agent 编写，遵循派单规范 |

---

## 📌 Phase 演进路线

| Phase | 范围 | 状态 |
| --- | --- | --- |
| **Phase 1** | 标准目录 + 模板 + `init-solution.sh` + `doctor.sh` | ✅ 当前版本 |
| Phase 2 | `generate-modules.sh`（从 REQ 自动拆模块草稿） | ⏳ 智院实战后实现 |
| Phase 3 | `sync-solution-map.sh`（REQ↔模块↔API↔代码 4 层映射表） | ⏳ |
| Phase 4 | `diff-against-reqs.sh`（需求变更时方案漂移告警） | ⏳ |

---

## 🎯 设计哲学（一句话）

> 先把骨架立住，再用实战补血肉。方案不是一次写完的文档，而是随项目演进的**结构化决策仓库**。
