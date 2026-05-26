---
name: planning
description: 项目立项 / 战略规划 skill。在 requirement 之前为项目沉淀 PRD（产品需求文档）/ ROADMAP（版本路线图）/ OKR（季度目标）三件套，作为后续需求拆分、原型设计、方案设计、开发部署的根锚。
metadata: {"openclaw":{"emoji":"🧭","os":["linux"],"requires":{"bins":["jq"]}}}
user-invocable: true
---

# planning — 项目立项 / 战略规划 Skill 🧭

> 在 `requirement` 之前先把"**为什么做、做给谁、做到什么程度、不做什么、怎么活下去**"想清楚。
> 输出 **PRD / ROADMAP / OKR** 三件套，作为后续 REQ / 原型 / 方案 / 开发的根锚。
> 版本：Phase 1（纯文件 + jq 索引，与 project-mgmt 联动）

---

## ⛔ 红线（违反 = 立即停手 + 在 MEMORY.md 补踩坑）

1. **planning 是项目第一个 stage**，**优先于 requirement**：没有 PRD.md 之前禁止把项目推进到 `requirement` 之后的任何阶段
2. **PRD/ROADMAP/OKR 草稿必须明确标注 `> 状态：draft（待龙哥审定）`**：未经龙哥审定的内容不得在群里、在外部对话里以"已确认"口吻使用
3. **商业模式 / 关键定位 / 主要用户画像 不许 AI 擅自拍板**：模板里如果出现"商业模式"等关键决策段，必须留 ≥2 个候选项 + 风险说明给龙哥选
4. **planning 三件套属于 docs-repos**：落到 `docs-repos/<project-id>/planning/`，不允许写到 `code-repos/` 或项目代码目录
5. **紧急 bug / hotfix 不卡 planning**：bugs/ 通道、临时 incident 通道保留，本 skill 不阻塞 `add-incident.sh` 等紧急流程
6. **不许直接改 project-mgmt 的 stage 流转架构**：本 skill 只在 `requirement skill` 加"软提醒"和在 profile.json 加 `planning_docs` 字段，不动既有 7 阶段状态机

---

## 🚦 启动前自检

```bash
bash {{SKILL_DIR}}/scripts/validate-planning.sh --doctor
```

- 输出 `READY` → 进入正常流程
- 输出 `NEED_SETUP: <原因>` → **暂停操作**，按 `setup.md` / README 修复

`{{SKILL_DIR}}` = `/var/lib/openclaw/.openclaw/workspace/skills/planning/`
落地目录 = `/var/lib/openclaw/.openclaw/workspace/docs-repos/<project-id>/planning/`

---

## 🗂️ 落地目录结构

```
docs-repos/<project-id>/planning/
├── PRD.md          # 产品需求文档（必填，draft 起步，最终由龙哥审定）
├── ROADMAP.md      # 版本路线图（必填，draft 起步）
├── OKR.md          # 季度 / 阶段目标（可选，建议有）
└── _archive/       # 历史快照（PRD-v1.md 等，由 archive 流程产出）
```

profile.json 关联字段（由 `sync-to-profile.sh` 写入）：

```jsonc
{
  "planning_docs": {
    "prd": "docs-repos/<id>/planning/PRD.md",
    "roadmap": "docs-repos/<id>/planning/ROADMAP.md",
    "okr": "docs-repos/<id>/planning/OKR.md",   // 可为 null
    "status": "draft",                           // draft | reviewing | approved
    "last_updated": "2026-05-26T22:00:00+08:00",
    "legacy": false                              // true=历史项目首次接入只补空壳
  }
}
```

---

## 📐 三件套必填字段（精简版，详见 templates/）

### PRD.md 必填字段
1. **一句话定位**（who + what + how，30 字内）
2. **目标用户画像**（主要角色 / 典型场景 / 核心痛点）
3. **核心价值主张**（差异化命门，与竞品/旧方案对比）
4. **MVP 范围**（✅ 做什么 + ❌ 明确不做什么）
5. **成功指标**（≥3 条量化指标，最好带时间窗）
6. **商业模式 / 商业目标**（候选项 + 默认选项，红线：≥2 候选）
7. **假设与风险**（≥3 条，每条配缓解或验证方式）

### ROADMAP.md 必填字段
- 版本号 | 主题 | 时间窗 | 关键能力 | 明确不做什么 | 验收标准 | 状态（done/doing/planned）
- 至少包含 **V1（MVP）/ V2（差异化）/ V3（规模化）** 三档

### OKR.md 必填字段（可选）
- O（Objective）+ ≥2 个 KR（Key Result，量化、可验收）
- 每个 KR 显式标 owner（默认龙哥+呆呆）和时间窗

---

## 📋 使用场景

### 场景 1：新项目立项（首次创建三件套）

```bash
bash {{SKILL_DIR}}/scripts/init-planning.sh <project-id>
# 例：
bash {{SKILL_DIR}}/scripts/init-planning.sh smartops
```

- 在 `docs-repos/<project-id>/planning/` 创建 PRD.md / ROADMAP.md / OKR.md 骨架（从 templates/ 拷贝）
- 每份文档 frontmatter 默认 `status: draft`
- 自动调用 `sync-to-profile.sh`，把路径写入 `knowledge-repos/projects/<id>/profile.json.planning_docs`
- 若 `docs-repos/<project-id>/` 不存在，会先报错提示（避免拼错 id）

### 场景 2：历史项目首次接入（迁移模式）

```bash
bash {{SKILL_DIR}}/scripts/init-planning.sh <project-id> --migrate
```

- 创建空壳骨架（同场景 1），但 frontmatter 标 `legacy: true`
- profile.json.planning_docs.legacy=true，dashboard / validate 会给出"未审定"提醒但不报错
- 后续龙哥按部就班补内容即可

### 场景 3：校验三件套完整性

```bash
bash {{SKILL_DIR}}/scripts/validate-planning.sh <project-id>
```

- 检查 PRD.md / ROADMAP.md 必填字段是否缺失（按章节标题扫）
- 检查 draft 状态、商业模式段是否给出 ≥2 候选项
- 输出彩色报告：✓ pass / ⚠ warning / ✗ error
- 出错 exit 1，可接 CI

### 场景 4：把 planning 路径同步到 profile.json

```bash
bash {{SKILL_DIR}}/scripts/sync-to-profile.sh <project-id>
```

- 自动读取 `docs-repos/<project-id>/planning/` 现有文件，写入 `profile.json.planning_docs`
- 兼容 OKR 缺失 → okr=null
- 内置幂等，多次调用结果一致
- `init-planning.sh` 末尾会自动调一次

### 场景 5：从 draft 转 approved（龙哥审定后）

```bash
bash {{SKILL_DIR}}/scripts/sync-to-profile.sh <project-id> --status approved
```

- 把 profile.json.planning_docs.status 从 draft → approved
- 同时把 PRD.md / ROADMAP.md frontmatter 的 `status: draft` 改为 `status: approved`
- 在 `knowledge-repos/projects/<id>/milestones.md` 追加 `PLANNING-APPROVED` 条记录（依赖 project-mgmt `add-milestone.sh`，缺失时降级 echo 提示）

---

## 🔄 与其他 Skill 的协同

| Skill | 关系 |
| --- | --- |
| `project-mgmt` | profile.json 新增 `planning_docs` 字段，仪表盘可展示"是否完成立项" |
| `requirement` | `trigger.sh` / `new-req.sh` 前会软提醒：未发现 PRD.md → 警告 + 提示跑 `init-planning.sh`，**不阻塞**（紧急 bug 通道保留） |
| `prototype-design` | 推荐先读 PRD.md 的"MVP 范围 / 核心价值"再生成原型，避免无锚漂移 |
| `solution-design` | ADR / 模块拆分前应对照 PRD.md 的"假设与风险"做技术决策 |
| `req-trigger` | 紧急 bug / 反馈通道不卡，但收到的反馈最终应能映射回 PRD 的某条 KR / MVP 范围 |

> 注意：本 skill **不直接修改** project-mgmt 的 7 阶段流转（`planning → requirement → design → develop → test → live → deprecated`），只是补齐 `planning` 阶段的实质产物。

---

## 🧪 自检与排错

- 三件套缺失 / draft 没改 → 跑 `validate-planning.sh <id>`
- profile.json 未联动 → 跑 `sync-to-profile.sh <id>`
- 历史项目要补：`init-planning.sh <id> --migrate`
- 大文件写入参考 `scripts/write-large-file.sh`
- 日期 / 时区统一 `Asia/Shanghai`

---

## 📌 Phase 路线

- **Phase 1（当前）**：三件套模板 + init/validate/sync 三脚本 + project-mgmt / requirement 软联动
- **Phase 2**：planning archive（PRD-v1.md 历史快照）+ 与 ADR 双向引用
- **Phase 3**：planning dashboard（哪些项目 PRD 未审定 / OKR 季度进度 / 路线图甘特）
- **Phase 4**：planning ↔ 需求/原型映射（覆盖率检查，未在 PRD MVP 范围的需求高亮）
