# 权舆科技 - 技能体系

## 技能分类

```
skills/
├── shared/                         ← 共用规范（所有AI必须遵守）
│   └── SKILL.md                    Git规范、命名规则、踩坑登记、通用部署规则
│
├── roles/                          ← 岗位职责操作技能（怎么干活）
│   ├── developer/SKILL.md          开发工程师：代码提交4步闭环、数据库红线
│   ├── reviewer/SKILL.md           代码审查员：审查清单、报告格式
│   ├── deployer/SKILL.md           部署运维：部署4步闭环、端口规则
│   ├── product-designer/SKILL.md   产品设计：需求文档规范、MVP原则
│   └── kb-writer/SKILL.md          知识库写入：目录分类、踩坑格式
│
├── modes/                          ← 工作模式技能（怎么管理任务）
│   ├── team-mode/SKILL.md          团队协作：调度者+多Agent，任务台账+超时处理
│   └── solo-mode/SKILL.md          单人作业：自拆解+自执行+自验证+自记录
│
└── quanyu-dev/                     ← 项目专用技能（特定技术栈约束）
    quanyu-deploy/                    权舆项目的 Next.js+tRPC+Prisma 特有规则
    quanyu-dispatch/
    quanyu-kb/
```

## 新AI接入指南

1. **必装**：`shared/`（共用规范）
2. **按岗位装**：`roles/` 下选对应的岗位技能
3. **按模式装**：`modes/` 下选团队模式或单人模式
4. **按项目装**：如参与权舆项目，加装 `quanyu-dev` 等项目专用技能

### 示例：晨曦学园AI接入
- ✅ `shared/` — 共用规范
- ✅ `roles/developer/` — 开发工程师
- ✅ `modes/solo-mode/` — 单人作业
- ❌ `modes/team-mode/` — 不需要（不受小缺调度）
- ❌ `quanyu-dev/` — 不需要（不同技术栈）

### 示例：新增权舆团队开发成员
- ✅ `shared/` — 共用规范
- ✅ `roles/developer/` — 开发工程师
- ✅ `modes/team-mode/` — 团队协作（受小缺调度）
- ✅ `quanyu-dev/` — 权舆技术栈约束

## 模式选择标准

| 条件 | 选择 |
|------|------|
| 有调度者统一管理多个Agent | **团队模式** team-mode |
| 一个AI独立负责一个项目 | **单人模式** solo-mode |
| AI直接接收创始人指令，自己拆解执行 | **单人模式** solo-mode |
| AI接受项目经理调度，只负责执行 | **团队模式** team-mode（作为执行者） |

**判断口诀：有调度者 → 团队模式；独立干活 → 单人模式。**
