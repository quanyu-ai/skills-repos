---
name: quanyu-test
description: 权舆科技测试验证规范。当任务涉及部署验证、功能测试、健康检查、数据验证时激活。
---

# 测试验证规范

## 测试流程

1. 接收测试任务（从项目经理或 TASK-TRACKER）
2. 阅读需求文档和 PRD
3. 编写测试计划（测试场景、测试数据）
4. 执行测试（功能测试 + 边界测试）
5. 输出测试报告（通过/不通过 + bug列表）
6. bug修复后验证 → 回归测试

## 参考规范

- 产品开发流程：`knowledge-repos/guides/product-dev-workflow.md`
- 踩坑登记册：`knowledge-repos/knowledge/internal/pitfall-registry.md`
