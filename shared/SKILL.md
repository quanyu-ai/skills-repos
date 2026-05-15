---
name: shared-conventions
description: 权舆科技共用规范。所有AI协作者必须遵守。涉及Git提交、仓库命名、踩坑登记、通用部署规则时激活。
---

# 共用规范（所有AI必须遵守）

## Git 提交规范

- commit message 格式：`feat:/fix:/docs:/refactor:/chore:/release: 描述`
- 提交前必须确认 build 通过
- 已 push 的代码不得 force push（除非创始人批准）

## 仓库命名规则

| 类别 | 规则 | 示例 |
|------|------|------|
| 项目代码 | `proj-code-` + 项目英文名 | `proj-code-quanyu-platform` |
| 技术栈骨架 | `skeleton-` + 技术栈（含数据库） | `skeleton-next-trpc-postgresql` |
| 专项仓库 | 主题名 + `-repos` | `docs-repos`、`config-repos` |

## 踩坑登记规则

- 踩坑统一登记到 `knowledge-repos` 的 `knowledge-repos/knowledge/internal/pitfall-registry.md`
- 格式：PIT-编号 + 标题 + 发现日期 + 标签 + 问题 + 根因 + 修复 + 预防规则 + 检查方式
- 开发前必须阅读与当前技术栈相关的踩坑条目
- 花了超过10分钟调试的问题 → 必须登记

## 通用部署规则

- 端口分配必须从 `INFRA-LEDGER.md` 的端口分配表中按顺序取用，禁止随意选端口
- 部署后必须验证服务可用（curl 健康检查 + API 通路验证）
- 未验证就报"部署完成" = 部署未完成

## 代码风格

- TypeScript：catch 块统一 `catch (error: any)` 或类型守卫
- 禁止硬编码密码、API Key、fallback 密钥
- 版本号禁止硬编码 fallback（如 `version || '1.0.0'`）

## 知识库写入规范

- 所有知识沉淀写入 `knowledge-repos`
- 内部经验 → `knowledge-repos/knowledge/internal/`
- 领域知识 → `knowledge-repos/knowledge/domain/`
- 复用模板 → `knowledge-repos/knowledge/templates/`
