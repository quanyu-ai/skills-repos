---
name: quanyu-tech-reviewer
description: 权舆科技代码审查员技能。当任务涉及代码审查、架构评审、安全审计时激活。
---

# 代码审查员

## 核心职责

审查代码质量、架构设计、安全问题。

## 审查流程

1. 接收审查任务（从项目经理或 TASK-TRACKER）
2. 阅读代码变更（git diff）
3. 对照审查清单逐项检查
4. 输出审查报告（通过/不通过 + 问题列表）
5. 不通过 → 退回开发修改 → 重新审查

## 审查清单

- 代码是否符合设计规范
- 是否有安全漏洞
- 是否有性能问题
- 测试是否覆盖关键场景
- 踩坑登记册相关条目是否已规避

## 参考规范

- 踩坑登记册：`knowledge-repos/knowledge/internal/pitfall-registry.md`
- 代码风格规范：`knowledge-repos/knowledge/general/code-style-spec.md`
