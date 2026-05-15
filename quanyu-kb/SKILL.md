---
name: quanyu-kb
description: 权舆科技知识库写入技能。当任务涉及写文档、记录经验、踩坑登记、更新规范、新建模板、知识沉淀、归档整理、知识迁移时激活。
---

# 权舆科技知识库写入技能

## 知识库位置

`knowledge-repos/knowledge/` 目录，总索引和编写规范见 `knowledge-repos/knowledge/index.md`。

## 写入前必读

阅读 `knowledge-repos/knowledge/index.md`，确认文件该放哪、怎么命名、头部格式。

## 目录速查

| 目录 | 放什么 | 审核 |
|------|--------|------|
| `general/` | 技术无关的通用规范 | 技术总监 |
| `domain/frontend/` | 前端知识（Next.js/Vue3/Taro等） | 技术总监 |
| `domain/backend/` | 后端知识（tRPC/Express/NestJS等） | 技术总监 |
| `domain/database/` | 数据库知识（Prisma/PostgreSQL/MySQL等） | 技术总监 |
| `domain/deployment/` | 部署知识（Docker/PM2/Nginx等） | 技术总监 |
| `domain/platforms/` | 运行环境（阿里云/腾讯云/客户服务器） | 技术总监 |
| `internal/` | 踩坑、经验、教训 | 无需审核 |
| `brand/` | 品牌资产、文案风格 | 产品总监 |
| `templates/code/<技术栈>/` | 代码模板 | 对应负责人 |
| `templates/project/` | 项目骨架/启动清单 | 对应负责人 |
| `templates/business/` | 提案、交付标准 | 产品总监 |
| `inbox/` | 无法归类的内容 | 无需审核 |

## 项目文档目录

项目文档在 `docs-repos/<project>/` 下，标准结构见 `knowledge-repos/knowledge/general/project-doc-structure.md`。
每个项目也有自己的 `inbox/` 目录，无法归类的项目文档先放这里。

## 文档头部模板

```markdown
# 文档标题

> **分类**：general / domain / internal / brand / templates
> **技术栈**：（如适用）
> **来源项目**：（如适用，如 权舆官网 / 晨曦学园 / 通用）
> **创建日期**：YYYY-MM-DD
> **最后更新**：YYYY-MM-DD
> **创建人**：（角色代号）
> **状态**：草稿 / 生效 / 归档
```

## 关键规则

1. **多技术栈兼容**：domain/ 按类别分目录，每个类别下按技术栈分文件并存
2. **标注来源**：从其他项目迁入的知识必须标注来源项目
3. **无法归类 → inbox/**：文件名 `YYYY-MM-DD-简短描述.md`，标注待归类
4. **不删除**：过时内容归档到 `_archive/`
5. **角色代号**：不硬编码人名
6. **写入后更新索引**：在 `knowledge-repos/knowledge/index.md` 的内容索引表中添加新文件记录
