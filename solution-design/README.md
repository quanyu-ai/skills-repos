# solution-design — 完整设计理念

## 为什么需要这个 skill

在没有标准化的方案设计流程之前，常见痛点：

- 一个项目的"架构图"散落在 5 个地方：龙哥脑子里、临时 chat、某个 README、PPT、wiki
- 数据库表结构改了，没人记录"为什么改"
- 新人接手项目，要花一周搞清楚"这玩意儿当初为啥这么设计"
- 需求变了，方案不变，代码改了一半才发现违反原架构

**solution-design 的目标**：把"方案"从口头/碎片化的状态，升级为**结构化、可索引、可演进的文档工程**。

## 核心原则

### 1. 一个项目一个 solution/ 目录

不许散落。所有方案相关文档统一收纳到 `docs-repos/<project>/solution/` 下。

### 2. 文档按维度拆分

| 维度 | 目录 | 内容 |
| --- | --- | --- |
| 总体架构 | `architecture/` | 分层、部署拓扑、数据流 |
| 数据模型 | `database/` | ER 图、表结构、索引策略 |
| API 契约 | `api/` | RESTful / tRPC 路由表 |
| 业务模块 | `modules/<name>/` | 单模块设计 + REQ 关联 + API 关联 |
| 决策记录 | `adr/` | 每条技术选择留档 |
| 元数据 | `meta/` | 版本、初始化时间等 |

### 3. ADR 是一等公民

任何"为什么这么选"必须留档。ADR 模板包含：

- **Status**：proposed / accepted / deprecated / superseded
- **Context**：什么场景 / 什么问题
- **Decision**：选了什么
- **Alternatives**：考虑过什么备选
- **Rationale**：为什么选这个
- **Consequences**：带来什么好处 / 代价

哪怕一句话也要写。**未来的自己会感谢现在的自己。**

### 4. 模块必须连接 REQ

每个 `modules/<name>/reqs.json` 列出该模块支撑的 REQ-ID 列表。
这是"需求→方案→代码"链路的关键一环，未来 Phase 3 会基于此生成全链路映射表。

### 5. 模板要简洁

每个模板 `.md` 不超过 50 行。**重要的是结构，不是字数。**
长篇大论的方案文档反而没人看。骨架先立住，内容随项目演进。

## Phase 演进路线

### Phase 1：轻量骨架

只做三件事：

1. 标准目录结构 + 简洁模板
2. `init-solution.sh`：一键初始化骨架
3. `doctor.sh`：自检模板完整性

### Phase 2（当前）：自动化闭环

在不替代人判断的前提下，建立「需求 ↔ 模块 ↔ API ↔ 代码」的索引和漂移监测：

| 脚本 | 作用 | 何时跑 |
| --- | --- | --- |
| `generate-modules.sh` | 从 REQ 关键词/角色拆模块草稿 | 需求初稿确认后一次性，或新增大批需求时 |
| `sync-solution-map.sh` | 生成 `solution-map.json`，建立反向映射 | 每次改 modules/ 后 |
| `diff-against-reqs.sh` | 检测方案漂移（缺失/孤儿/空模块/无效引用） | 需求变更后、每次提交前 |
| `validate-solution.sh` | 分级完整性校验（P0/P1/P2） | 提交、部署、阶段评审前 |

核心数据结构（`solution-map.json`）：

```json
{
  "stats": { "modules": 11, "reqs": 95, "apis": 76, "code_files": 0 },
  "modules": [ {"name":"academic-management", "reqs":[...], "apis":[...]} ],
  "req_module_map": { "REQ-20260522-014": ["academic-management"] },
  "req_api_map":    { "REQ-20260522-030": [{"module":"academic-management","method":"GET","path":"/grades","api_id":"AM-001"}] },
  "api_code_map":   { "academic-management:GET /grades": ["app/api/grades/route.ts"] }
}
```

### Phase 3：测试 / 原型反向索引

原型页面 ↔ 模块；测试用例 ↔ API。让"改动影响范围"四层都可查。

### Phase 4：跨项目方案模板复用

沉淀标准化的鉴权 / 通知 / 审批模块设计，作为子模板。

## 概念澄清：方案设计 vs 设计技能

### 方案设计（Solution Design）
方案设计是产品开发初期的**技术架构和实现方案规划**阶段，专注于：
- 技术选型决策（ADR）
- 系统架构设计（分层、部署拓扑、数据流）
- 模块拆分和接口定义
- 数据库设计（ER 图、表结构、索引策略）
- API 设计（RESTful / tRPC 路由表）
- 技术风险评估和解决方案

### solution-design 技能的功能定位

**solution-design 是方案设计阶段的标准化工作流**，帮助团队在编码之前建立清晰的技术蓝图。它不负责界面设计（那是 prototype-design 的事），也不负责需求管理（那是 requirement skill 的事），而是专注于**「怎么实现」**的技术决策。

### solution-design 的主要工作

| 工作领域 | 具体内容 | 产出物 | 对应目录 |
|---------|---------|--------|----------|
| **技术架构** | 分层架构、部署拓扑、数据流、技术栈选型 | 总架构 overview.md、模块全景图、数据流图、部署架构图 | `architecture/` |
| **模块拆分** | 从需求推导模块、定义模块边界、模块间依赖关系 | 模块设计文档、REQ 映射、API 清单 | `modules/<name>/` |
| **API 设计** | 路由表、请求/响应模型、错误码、鉴权策略 | API 契约文档、模块 API 清单 | `api/api-design.md` + `modules/<name>/apis.json` |
| **数据库设计** | ER 图、表结构、索引策略、JSONB 字段规划 | 表结构文档、ER 图、索引策略 | `database/` |
| **决策记录** | 技术选型理由、备选方案对比、实施后果 | ADR 文档 | `adr/` |

### 设计技能的层次
设计技能是一个更宽泛的概念，在 OpenClaw 技能体系中分为两个主要分支：

| 技能名称 | 功能定位 | 主要工作 |
|---------|----------|----------|
| **solution-design** | 方案设计阶段 | 技术架构、模块拆分、API 设计、数据库设计 |
| **prototype-design** | 原型设计阶段 | 界面设计、交互设计、可交互原型生成 |

### 与其他 skill 的边界

| skill | 责任 | 与 solution-design 的关系 |
| --- | --- | --- |
| `requirement` | 需求条目化管理 | solution 的 `modules/*/reqs.json` 引用其 REQ-ID |
| `prototype-design` | 原型 HTML 生成 | Phase 2 会引入原型与模块的显式关联 |
| `dispatch-task` | 子任务派发规范 | 复杂模块设计派子 Agent 写，方案 skill 提供模板 |
| `deploy-app` | 部署运维 | 方案的 `architecture/deployment.md` 描述部署拓扑 |

## 反模式（禁止）

- ❌ 在项目根目录放 `ARCHITECTURE.md`、`DESIGN.md` 等散落文档
- ❌ ADR 写"看代码就知道了"（违背 ADR 的存在意义）
- ❌ 模块设计文档没有 `reqs.json`
- ❌ 一个 `solution/overview.md` 把所有内容塞一起
- ❌ 用 OpenClaw 的 `write` 工具写超过 10KB 的方案文档（用 `write-large-file.sh`）

## FAQ

**Q: 老项目已经有散落的方案文档，怎么办？**
A: 跑 `init-solution.sh` 创建骨架，然后人工把老文档拆解填入对应位置。Phase 2 会出迁移辅助脚本。

**Q: 一个模块涉及多个 REQ，怎么管理？**
A: `reqs.json` 是数组，直接列多个 REQ-ID 即可。

**Q: 方案版本怎么管？**
A: `meta/version.json` 记录方案版本号。Git 是真正的版本仓库，方案的每次大改动应 commit。

**Q: 跨项目共享方案怎么办？**
A: Phase 4+ 考虑。当前每个项目独立维护，重复内容靠 ADR 引用解决。
