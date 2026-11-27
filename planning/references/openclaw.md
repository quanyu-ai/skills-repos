# 项目立项与规划的 OpenClaw 适配

本文适用于已采用此套脚本和目录约定的项目。运行前确认实际技能根目录、依赖和写入目标。文中的默认路径为该部署方式的路径，命令须指向当前实例。

## 规划与采用边界

先明确用户、问题、实际目标和关键取舍。项目已有有效方案时直接复用，不为进入下阶段补 PRD/ROADMAP/OKR 空壳或重复审批。尚未决定的商业定位明确待定及影响，不强制凑两个选项，也不指定某个个人为通用审批人。

下列目录和字段仅是本适配器生成格式。项目选择此适配器后按其真实输入调用；不用这些脚本也能完成规划。草稿与已确认结论应如实区分，记录在项目原来源。

---

## 🚦 启动前自检

```bash
bash {{SKILL_DIR}}/scripts/validate-planning.sh --doctor
```

- 输出 `READY` → 进入正常流程
- 输出 `NEED_SETUP: <原因>` → 仅处理本次所需工具的缺项，其他独立工作继续；按 `setup.md` / README 修复

`{{SKILL_DIR}}` = `/var/lib/openclaw/.openclaw/workspace/skills/planning/`
落地目录 = `/var/lib/openclaw/.openclaw/workspace/docs-repos/<project-id>/planning/`

---

## 🗂️ 落地目录结构

```
docs-repos/<project-id>/planning/
├── PRD.md          # 产品需求文档（按项目需要，未确认内容标明草稿）
├── ROADMAP.md      # 版本路线图（需要时维护）
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

## 生成器模板字段（仅使用该模板时适用）

### PRD.md 必填字段
1. **一句话定位**（who + what + how，30 字内）
2. **目标用户画像**（主要角色 / 典型场景 / 核心痛点）
3. **核心价值主张**（差异化命门，与竞品/旧方案对比）
4. **MVP 范围**（✅ 做什么 + ❌ 明确不做什么）
5. **成功指标**（≥3 条量化指标，最好带时间窗）
6. **商业模式 / 商业目标**（已确认依据；仅存在取舍时列相关选项）
7. **假设与风险**（≥3 条，每条配缓解或验证方式）

### ROADMAP.md 必填字段
- 版本号 | 主题 | 时间窗 | 关键能力 | 明确不做什么 | 验收标准 | 状态（done/doing/planned）
- 至少包含 **V1（MVP）/ V2（差异化）/ V3（规模化）** 三档

### OKR.md 必填字段（可选）
- 与当前目标有关的 Objective / Key Result；数量按实际问题决定
- 每个 KR 显式标 owner（项目实际负责人）和时间窗

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
- 沿项目实际负责人补足影响当前工作的内容

### 场景 3：检查已采用的规划文件

```bash
bash {{SKILL_DIR}}/scripts/validate-planning.sh <project-id>
```

- 只检查已存在的模板文件可读且非空；不以标题、选项数量或文件齐套判断规划成立
- 不以审批标签、选项数量或章节标题替代内容判断
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

### 场景 5：从 draft 转 approved（项目实际决定确认后）

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
