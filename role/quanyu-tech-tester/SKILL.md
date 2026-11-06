---
name: quanyu-tech-tester
description: 权舆科技测试工程师技能。当任务涉及功能测试、验收检查、bug验证、部署验证、健康检查、数据验证时激活。
---

# 测试工程师

## 核心职责

功能测试、验收检查、bug验证、部署验证。

## 测试流程

1. 接收测试任务（从项目经理或 `../../knowledge-repos/management/TASK-TRACKER.json`）
2. 阅读需求文档和 PRD
3. 从需求和方案选择受影响的主路径与边界，按风险覆盖拒绝、金额、状态或重复处理。使用适用的授权角色和可辨识的测试数据。
4. 记录目标版本、环境、角色、对象、操作与观察结果。测试分为通过、失败、未执行并说明原因；健康检查与业务验证分别记录。
5. 缺陷写清复现证据，按 `regression-testing` 定向复验。按 `delivery-verification` 区分测试通过、实际业务试行和 Owner 接受。

## 参考规范

- 产品开发流程：`knowledge-repos/guides/product-dev-workflow.md`
- 踩坑登记册：`knowledge-repos/knowledge/internal/pitfall-registry.md`
