# 权舆科技 - 技能体系

## 技能分类

```
skills/
├── role/                           ← 岗位技能（按角色装）
│   ├── quanyu-tech-director/       软件研发总监：任务调度、进度跟踪、超时处理
│   ├── quanyu-tech-developer/      开发工程师：范围验证、故障定位、数据库边界
│   ├── quanyu-tech-reviewer/       代码审查员：审查清单、报告格式
│   ├── quanyu-tech-deployer/       部署运维：部署4步闭环、一键脚本
│   ├── quanyu-tech-product-designer/ 产品设计：PRD→原型→评审→交付
│   └── quanyu-tech-tester/         测试工程师：测试流程、验收检查
│
└── mode/                           ← 工作模式（按场景装）
    ├── quanyu-tech-team/           团队协作：调度者+多Agent，任务台账+超时处理
    └── quanyu-tech-solo/           单人作业：自拆解+自执行+自验证+自记录
```

通用规范、各类资产的关系及 GitHub 迭代方式见[自建软件开发工程技能体系指引](docs/software-engineering-system.md)。

## 软件开发流程

| 阶段 | 技能与交付物 |
| --- | --- |
| 立项、需求、设计 | [立项](planning/SKILL.md)、[需求](requirement/SKILL.md)、[方案](solution-design/SKILL.md)与[原型](prototype-design/SKILL.md)确认目标、关键决定和验收行为。交互变更按需制作原型，实质变更交接前运行[原型评审](prototype-review/SKILL.md)。可按项目需要[接入交接检查](prototype-review/references/hook-integration.md)。 |
| 实施准备 | [实施计划](implementation-planning/SKILL.md)把已明确的设计拆成带责任、边界和检查的业务切片。 |
| 开发、测试与修复 | [行为与回归测试](regression-testing/SKILL.md)验证关键行为和可复现缺陷。[系统排错](engineering-debugging/SKILL.md)在出现异常时定位和验证根因。 |
| 评审与交付 | [代码评审](role/quanyu-tech-reviewer/SKILL.md)核对规格与工程质量。[交付核验](delivery-verification/SKILL.md)判定各项完成声明，并衔接项目已有发布入口。 |

角色技能定义职责，工作模式决定协作方式。按当前任务选用所需技能，小改动直接做受影响检查。沿用项目已有交付记录和发布权限。

借鉴来源：[设计澄清](https://github.com/obra/superpowers/blob/main/skills/brainstorming/SKILL.md)、[可验证计划](https://github.com/obra/superpowers/blob/main/skills/writing-plans/SKILL.md)、[系统排错](https://github.com/obra/superpowers/blob/main/skills/systematic-debugging/SKILL.md)、[测试先失败再通过](https://github.com/obra/superpowers/blob/main/skills/test-driven-development/SKILL.md)、[代码评审交接](https://github.com/obra/superpowers/blob/main/skills/requesting-code-review/SKILL.md)与[完成前核验证据](https://github.com/obra/superpowers/blob/main/skills/verification-before-completion/SKILL.md)。

## 命名规则

- 通用流程技能按实际工程用途命名。角色和模式技能使用 `quanyu-tech-` 前缀。
- 角色技能：`quanyu-tech-角色名`（director/developer/reviewer/deployer/product-designer/tester）
- 模式技能：`quanyu-tech-模式名`（team/solo）

## 新AI接入指南

1. **按岗位装**：`role/` 下选对应的岗位技能
2. **按模式装**：`mode/` 下选 team 或 solo

立项、项目档案、需求、方案和原型技能的入口说明可供不同工具和人工团队共用。入口定义交付物、业务约束和验收条件；运行环境的目录、脚本和依赖由项目按需采用，参考各技能的 `references/`。单执行者可选用 `quanyu-tech-solo` 管理任务切片与交付证据。

### 示例：晨曦学园AI接入
- ✅ `role/quanyu-tech-developer/` — 开发工程师
- ✅ `mode/quanyu-tech-solo/` — 单人作业
- ❌ `mode/quanyu-tech-team/` — 不需要（不受小缺调度）

### 示例：新增权舆团队开发成员
- ✅ `role/quanyu-tech-developer/` — 开发工程师
- ✅ `mode/quanyu-tech-team/` — 团队协作（受小缺调度）

## 模式选择标准

| 条件 | 选择 |
|------|------|
| 有调度者统一管理多个Agent | **团队模式** quanyu-tech-team |
| 一个AI独立负责一个项目 | **单人模式** quanyu-tech-solo |
| AI直接接收创始人指令，自己拆解执行 | **单人模式** quanyu-tech-solo |
| AI接受项目经理调度，只负责执行 | **团队模式** quanyu-tech-team（作为执行者） |

**判断口诀：有调度者 → 团队模式；独立干活 → 单人模式。**

## Codex 统一插件

14项通用技能通过[权舆工程技能插件](docs/codex-plugin.md)统一安装和更新；现有目录继续作为唯一源码，项目专属规则留在各项目。
