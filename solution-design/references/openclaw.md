# 方案设计的 OpenClaw 适配

本文适用于已采用此套脚本和目录约定的项目。运行前确认实际技能根目录、依赖和写入目标。文中的默认路径为该部署方式的路径，命令须指向当前实例。

## 🚦 启动前自检（OpenClaw 自动化）

```bash
bash {{SKILL_DIR}}/scripts/doctor.sh
```

- 输出 `READY` → 进入正常流程
- 输出 `NEED_SETUP: <原因>` → 仅处理本次所需工具的缺项，其他独立工作继续；按 `setup.md` 补齐

`{{SKILL_DIR}}` = `/var/lib/openclaw/.openclaw/workspace/skills/solution-design/`

---

## 方案与工具约定

方案解释如何完成用户任务、真实数据与权限、失败和恢复，以及重要取舍。沿用已有需求和方案；只有需要长期追踪的重要决定才新增 ADR，不把每个选择写成一个审批或独立文件。

下列目录、reqs.json 和自动索引是本适配器格式，不是通用交付门槛。使用生成器时保护已有文件及索引；不使用它时沿项目原方案维护。生成骨架不等于方案成立，补足实际业务内容后按变化风险核对，不固定新增人工审阅人。

---

## 📋 标准使用场景

### 场景 1：项目首次初始化方案目录

```bash
bash {{SKILL_DIR}}/scripts/init-solution.sh <project>
# 例：bash scripts/init-solution.sh smart-college
```

效果：在 `docs-repos/<project>/solution/` 生成完整骨架（架构 / 数据库 / API / 模块示例 / ADR / meta）。

### 场景 2：从需求自动生成模块草稿（Phase 2）

```bash
bash {{SKILL_DIR}}/scripts/generate-modules.sh <project> --dry-run             # 先看候选
bash {{SKILL_DIR}}/scripts/generate-modules.sh <project>                       # 关键词匹配
bash {{SKILL_DIR}}/scripts/generate-modules.sh <project> --from-roles          # 按"角色-模块"标题拆分
bash {{SKILL_DIR}}/scripts/generate-modules.sh <project> --force               # 覆盖空骨架模块
```

策略：
- `--from-roles`：要求需求标题形如 `学生-学业预警`、`教师-学生指导`，按破折号后的部分聚合
- 默认：用领域关键词词典（用户/审批/通知/工作台/报表 …）粗匹配
- 生成结果**按本次风险复核**，再补 `apis.json`

### 场景 3：同步「需求 ↔ 模块 ↔ API ↔ 代码」映射

```bash
bash {{SKILL_DIR}}/scripts/sync-solution-map.sh <project>           # 实生成
bash {{SKILL_DIR}}/scripts/sync-solution-map.sh <project> --dry-run # 仅预览
bash {{SKILL_DIR}}/scripts/sync-solution-map.sh <project> --quiet   # CI 模式
```

输出 `docs-repos/<project>/solution/solution-map.json`，含：
- `modules[]`：每个模块的 reqs / apis 标准化清单
- `req_module_map`：`REQ-ID → [module]`
- `req_api_map`：`REQ-ID → [{module, method, path, ...}]`
- `api_code_map`：API 路径 → 源码文件（需 `projects/<project>/src/` 存在）
- `stats`：模块/需求/API/代码文件数量

### 场景 4：检测方案漂移

```bash
bash {{SKILL_DIR}}/scripts/diff-against-reqs.sh <project>                       # 控制台报告
bash {{SKILL_DIR}}/scripts/diff-against-reqs.sh <project> --report /tmp/drift.md
bash {{SKILL_DIR}}/scripts/diff-against-reqs.sh <project> --fail-on-warn        # CI 严格模式
```

检测：
- `MISSING_IN_SOLUTION`：需求未关联到任何模块（WARN）
- `ORPHAN_IN_SOLUTION`：方案引用了已删除的需求（ERROR）
- `EMPTY_MODULE` / `MODULE_NO_API`：模块空骨架（WARN）
- `API_REQ_NOT_FOUND`：API 标的 REQ-ID 不存在（ERROR）
- `REQ_IN_MULTIPLE_MODULES`：同一需求关联多个模块（INFO）

退出码：0=通过 / 1=有 WARN（仅 `--fail-on-warn` 时）/ 2=有 ERROR。

### 场景 5：方案完整性校验

```bash
bash {{SKILL_DIR}}/scripts/validate-solution.sh <project>                     # 标准
bash {{SKILL_DIR}}/scripts/validate-solution.sh <project> --strict            # P1 失败也算致命
bash {{SKILL_DIR}}/scripts/validate-solution.sh <project> --report /tmp/v.md
```

P0/P1/P2 分级；P0 涵盖目录结构 / 必备文件 / JSON 合法性 / 模块三件套；P1 涵盖占位符清理 / ADR 数量 / solution-map 存在；P2 提示模块设计文档过短。

### 场景 6：新增一条 ADR

```bash
PROJECT=smart-college
ADR_DIR=docs-repos/$PROJECT/solution/adr
NEXT=$(printf "%03d" $(($(ls $ADR_DIR/ADR-*.md 2>/dev/null | wc -l) + 1)))
cp {{SKILL_DIR}}/templates/adr-template.md $ADR_DIR/ADR-${NEXT}-<short-title>.md
```

### 场景 7：新增一个模块（手工）

```bash
cp -r docs-repos/<project>/solution/modules/_example docs-repos/<project>/solution/modules/<module-name>
# 然后编辑 design.md / reqs.json / apis.json
# 编辑完跑 sync-solution-map.sh 重建映射
```

---

## 🔁 推荐工作流

```
需求确认（requirement skill）
        ↓
init-solution.sh              ← 仅首次
        ↓
generate-modules.sh --dry-run ← 看候选
        ↓
generate-modules.sh           ← 实生成草稿
        ↓
人工 review / 补充 design.md / apis.json
        ↓
sync-solution-map.sh          ← 建立映射
        ↓
diff-against-reqs.sh          ← 检测漂移（每次需求变更后）
        ↓
validate-solution.sh          ← 提交/部署前完整性校验
```

---

## 🧩 与其他 skill 的联动

| 上游 / 下游 | 关系 |
| --- | --- |
| `requirement` | 模块的 `reqs.json` 引用 REQ-ID；漂移检测以 `requirements/` 为信任源 |
| `prototype-design` | 方案模块可关联原型页面（Phase 3 引入显式索引） |
| `dispatch-task` | 复杂模块设计派子 Agent 编写 |
| `deploy-app` | `architecture/deployment.md` 描述部署拓扑，对应 `apps.json` 配置 |

---

## 📌 Phase 演进路线

| Phase | 范围 | 状态 |
| --- | --- | --- |
| **Phase 1** | 标准目录 + 模板 + `init-solution.sh` + `doctor.sh` | ✅ |
| **Phase 2** | `generate-modules.sh` + `sync-solution-map.sh` + `diff-against-reqs.sh` + `validate-solution.sh` | ✅ 当前 |
| Phase 3 | 原型页面 ↔ 模块显式索引；测试用例 ↔ API 反向映射 | ⏳ |
| Phase 4 | 跨项目方案模板复用（如：标准鉴权模块、通用通知模块） | ⏳ |

---

## 🎯 设计哲学（一句话）

> 先把骨架立住，再用实战补血肉；自动化只做"映射 + 漂移检测"，**判断永远留给人**。
