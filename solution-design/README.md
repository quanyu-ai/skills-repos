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

### Phase 1（当前版本）：轻量骨架

只做三件事：

1. 标准目录结构 + 简洁模板
2. `init-solution.sh`：一键初始化骨架
3. `doctor.sh`：自检模板完整性

**不做**：自动生成业务内容、不做映射、不做差异告警。

### Phase 2：generate-modules.sh

从 `requirement` skill 的 REQ 列表，自动推断模块拆分，生成 `modules/<name>/design.md` 草稿。
龙哥审一遍，去伪存真。

### Phase 3：sync-solution-map.sh

建立 REQ ↔ 模块 ↔ API ↔ 代码文件 4 层映射表。
任意一端改动，可以查出影响范围。

### Phase 4：diff-against-reqs.sh

当 REQ 状态变化（新增/废弃/修改），扫描 solution/ 找出受影响的模块和 ADR，输出"方案漂移告警"。

## 与其他 skill 的边界

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
