---
name: shared-conventions
description: 权舆科技共用规范入口。所有AI协作者必须遵守的基础规则。
---

# 共用规范（所有AI必须遵守）

## 仓库命名规则

| 类别 | 规则 | 示例 |
|------|------|------|
| 项目代码 | `proj-code-` + 项目英文名 | `proj-code-quanyu-platform` |
| 技术栈骨架 | `skeleton-` + 技术栈（含数据库） | `skeleton-next-trpc-postgresql` |
| 专项仓库 | 主题名 + `-repos` | `docs-repos`、`config-repos` |

## 知识库写入

- 所有知识沉淀写入 `knowledge-repos`
- 内部经验 → `knowledge-repos/knowledge/internal/`
- 领域知识 → `knowledge-repos/knowledge/domain/`
- 复用模板 → `knowledge-repos/knowledge/templates/`

## 参考规范

- Git 提交规范：`knowledge-repos/knowledge/general/git-commit-spec.md`
- 仓库命名规范：`knowledge-repos/knowledge/general/repo-naming-spec.md`
- 代码风格规范：`knowledge-repos/knowledge/general/code-style-spec.md`
- 部署规则规范：`knowledge-repos/knowledge/general/deployment-rules-spec.md`
- 知识库写入规范：`knowledge-repos/knowledge/general/knowledge-base-writing-spec.md`
- 踩坑登记册：`knowledge-repos/knowledge/internal/pitfall-registry.md`
