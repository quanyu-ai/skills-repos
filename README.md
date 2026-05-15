# 权舆科技 - 技能体系

## 技能分类

```
skills/
├── role/                           ← 岗位技能（按角色装）
│   ├── quanyu-tech-director/       软件研发总监：任务调度、进度跟踪、超时处理
│   ├── quanyu-tech-developer/      开发工程师：代码提交4步闭环、数据库红线
│   ├── quanyu-tech-reviewer/       代码审查员：审查清单、报告格式
│   ├── quanyu-tech-deployer/       部署运维：部署4步闭环、一键脚本
│   ├── quanyu-tech-product-designer/ 产品设计：PRD→原型→评审→交付
│   └── quanyu-tech-tester/         测试工程师：测试流程、验收检查
│
└── mode/                           ← 工作模式（按场景装）
    ├── quanyu-tech-team/           团队协作：调度者+多Agent，任务台账+超时处理
    └── quanyu-tech-solo/           单人作业：自拆解+自执行+自验证+自记录
```

## 命名规则

- 统一前缀：`quanyu-tech-`（权舆 + 部门）
- 角色技能：`quanyu-tech-角色名`（director/developer/reviewer/deployer/product-designer/tester）
- 模式技能：`quanyu-tech-模式名`（team/solo）

## 新AI接入指南

1. **按岗位装**：`role/` 下选对应的岗位技能
2. **按模式装**：`mode/` 下选 team 或 solo

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
