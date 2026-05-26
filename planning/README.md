# planning skill — 项目立项 / 战略规划 🧭

> 在 `requirement` 之前先沉淀 **PRD / ROADMAP / OKR** 三件套，作为后续 REQ / 原型 / 方案 / 开发 / 部署的根锚。
> 让"为什么做、做给谁、做到什么程度、不做什么、怎么活下去"先于功能拆分被回答。
>
> Phase 1：纯文件 + jq 索引 + 与 `project-mgmt` / `requirement` 软联动。

---

## 🧭 这个 skill 是干什么的？

`project-mgmt` 的 7 阶段状态机里，`planning` 是第一个 stage，但之前是**空壳**：没有产物模板、没有触发脚本、没有验收标准。结果就是项目跳过立项直接做需求，然后"业务背景"段全是反推出来的空话。

本 skill 把 `planning` 这个空壳填上肉：

- **统一三件套**：PRD（产品需求文档）/ ROADMAP（版本路线图）/ OKR（季度目标）
- **统一目录**：`docs-repos/<project-id>/planning/`
- **统一脚本**：`init-planning.sh` / `validate-planning.sh` / `sync-to-profile.sh`
- **统一字段**：profile.json 加 `planning_docs` 字段，dashboard / requirement skill 都能联动

---

## 🚦 三大原则（红线）

1. **planning 优先于 requirement**：没有 PRD.md 之前禁止把项目推进到 `requirement` 之后
2. **AI 起草，龙哥审定**：所有 PRD/ROADMAP/OKR 初稿一律 `status: draft`，审定后通过 `sync-to-profile.sh --status approved` 切状态
3. **关键决策不许 AI 拍板**：商业模式 / 主要用户画像 / 一句话定位等关键段必须列 ≥2 候选项给龙哥圈选（自用工具可写"自用，不卖"作为单一选项）

---

## 🗂️ 落地目录结构

```
docs-repos/<project-id>/planning/
├── PRD.md          # 产品需求文档（必填）
├── ROADMAP.md      # 版本路线图（必填，至少 V1/V2/V3 三档）
├── OKR.md          # 季度 / 阶段目标（可选，建议有）
└── _archive/       # 历史快照（PRD-v1.md 等，Phase 2 启用）
```

profile.json 关联字段：

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

## 📋 三大场景

### 场景 1：新项目立项

```bash
bash skills/planning/scripts/init-planning.sh smartops
```

- 在 `docs-repos/smartops/planning/` 创建 PRD/ROADMAP/OKR 骨架
- 自动同步路径到 `knowledge-repos/projects/smartops/profile.json.planning_docs`
- 默认 `status: draft`，等龙哥审定

### 场景 2：历史项目首次接入

```bash
bash skills/planning/scripts/init-planning.sh smartops --migrate
```

- 同样建骨架，但 frontmatter 标 `legacy: true`
- dashboard / validate 会显示"未审定"提醒但不报错（容忍补内容）

### 场景 3：校验三件套完整性

```bash
bash skills/planning/scripts/validate-planning.sh smartops
bash skills/planning/scripts/validate-planning.sh --all        # 校验所有项目
bash skills/planning/scripts/validate-planning.sh --doctor     # skill 自检
```

输出彩色报告：✓ pass / ⚠ warning / ✗ error。
错误退出码 1，可接 CI。

### 场景 4：审定后状态切换

```bash
bash skills/planning/scripts/sync-to-profile.sh smartops --status approved
```

- 把 `profile.json.planning_docs.status` 从 draft → approved
- 同步把 PRD/ROADMAP/OKR frontmatter 的 `status: draft` 改为 `status: approved`
- 在 `knowledge-repos/projects/<id>/milestones.md` 追加 `PLANNING-APPROVED` 条记录（依赖 project-mgmt `add-milestone.sh`，缺失时降级 echo 提示）

---

## 📐 三件套必填字段速查

### PRD.md 必填段
1. **一句话定位**（who + what + how，30 字内）
2. **目标用户画像**（主要角色 / 典型场景 / 核心痛点）
3. **核心价值主张**（差异化命门，与竞品/旧方案对比）
4. **MVP 范围**（✅ 做什么 + ❌ 明确不做什么）
5. **成功指标**（≥3 条量化指标）
6. **商业模式 / 商业目标**（≥2 候选项，自用工具可单选"自用，不卖"）
7. **假设与风险**（≥3 条，每条配缓解或验证方式）

### ROADMAP.md 必填段
- 版本号 / 主题 / 时间窗 / 关键能力 / 不做什么 / 验收标准 / 状态
- 至少 **V1（MVP）/ V2（差异化）/ V3（规模化）**

### OKR.md 必填段（可选）
- O（Objective）+ ≥2 KR（Key Result）
- 每个 KR 显式标 owner 和时间窗

---

## 📦 模板设计要点

- 每个填空段都给「示例（正例）✅」+「反例 ❌」对照（学习成本最低）
- 草稿头部明确标注 `> 状态：draft（待龙哥审定）`
- 末尾留「变更历史」段，配合 ADR 体系
- frontmatter 含 `status` / `legacy` / `owner` / `version` 等结构化字段

---

## 🔄 与其他 Skill 的协同

| Skill | 关系 |
| --- | --- |
| `project-mgmt` | profile.json 新增 `planning_docs` 字段，仪表盘可展示"是否完成立项" |
| `requirement` | `new-req.sh` 前会软提醒：未发现 PRD.md → 警告 + 提示跑 `init-planning.sh`，**不阻塞**（紧急 bug 通道保留） |
| `req-trigger` | 紧急反馈通道不卡，但最终应能映射回 PRD 的某条 KR / MVP 范围 |
| `prototype-design` | 推荐先读 PRD.md 的"MVP 范围 / 核心价值"再生成原型 |
| `solution-design` | ADR / 模块拆分前应对照 PRD.md 的"假设与风险"做技术决策 |

> 本 skill **不修改** project-mgmt 的 7 阶段流转架构，只补 `planning` 阶段的实质产物。

---

## 🧪 自检与排错

```bash
# skill 自检（模板/脚本/依赖齐全）
bash skills/planning/scripts/validate-planning.sh --doctor

# 单项目校验
bash skills/planning/scripts/validate-planning.sh smartops

# 全项目扫一遍
bash skills/planning/scripts/validate-planning.sh --all
```

常见问题：
- `jq: command not found` → `apt-get install jq` 或 `brew install jq`
- profile.json 未联动 → 跑 `sync-to-profile.sh <id>`
- 历史项目要补：`init-planning.sh <id> --migrate`
- 日期 / 时区统一 `Asia/Shanghai`

---

## 📌 Phase 路线

- **Phase 1（当前）**：三件套模板 + init/validate/sync 三脚本 + project-mgmt / requirement 软联动
- **Phase 2**：planning archive（PRD-v1.md 历史快照）+ 与 ADR 双向引用
- **Phase 3**：planning dashboard（哪些项目 PRD 未审定 / OKR 季度进度 / 路线图甘特）
- **Phase 4**：planning ↔ 需求/原型映射（覆盖率检查，未在 PRD MVP 范围的需求高亮）

---

## 📁 文件清单

```
skills/planning/
├── SKILL.md                          # 触发入口 + 红线 + 流程
├── README.md                         # 本文件
├── templates/
│   ├── PRD.template.md               # PRD 模板（含示例/反例）
│   ├── ROADMAP.template.md           # ROADMAP 模板
│   └── OKR.template.md               # OKR 模板（可选）
└── scripts/
    ├── init-planning.sh              # 创建三件套骨架
    ├── validate-planning.sh          # 校验完整性 / skill 自检
    └── sync-to-profile.sh            # 同步 planning_docs 到 profile.json
```

---

## 🌸 设计哲学（呆呆 note）

立项不是"先想清楚再做"——是"先把'怎么知道做对了'写下来"。
PRD 不是"产品文档"，是"想清楚 → 写下来 → 龙哥能 5 分钟读完 → 团队能据此对齐"的载体。
ROADMAP 不是"承诺时间表"，是"每个版本主题只能 1 个、不做什么必须明写"的纪律工具。
OKR 不是"KPI"，是"让我们知道这季度是不是真的进步了"的镜子。

所以这个 skill 的核心不在脚本，在三个模板里那一段段「示例 ✅ / 反例 ❌」——它在教 AI 和人类一起写出"龙哥审定友好"的立项文档。
