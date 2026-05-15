---
name: role-kb-writer
description: 知识库写入岗位技能。当任务涉及写文档、记录经验、踩坑登记、知识沉淀时激活。
---

# 知识库写入岗位技能

## 职责

知识沉淀、经验记录、踩坑登记、文档归档整理。

## 写入目标仓库

`knowledge-repos`（GitHub: quanyu-ai/knowledge-repos）

## 目录分类

| 目录 | 内容 |
|------|------|
| `knowledge-repos/knowledge/internal/` | 团队内部经验、踩坑登记册 |
| `knowledge-repos/knowledge/domain/` | 领域知识（按技术栈分子目录） |
| `knowledge-repos/knowledge/general/` | 通用知识 |
| `knowledge-repos/knowledge/templates/` | 复用模板 |
| `knowledge-repos/knowledge/inbox/` | 待整理 |
| `knowledge-repos/guides/` | 职责手册、流程规范 |

## 踩坑登记格式

```markdown
### PIT-XXX | 简短标题
- **发现日期**：YYYY-MM-DD
- **标签**：`标签1` `标签2`
- **问题**：出了什么问题
- **根因**：为什么会出这个问题
- **修复**：怎么修的
- **预防规则**：以后怎么避免
- **检查方式**：怎么验证没有这个问题
```
