---
name: quanyu-seed
description: 权舆科技样板数据编写规范。当任务涉及创建演示数据、种子数据、seed脚本、样板数据时激活。
---

# 种子数据编写规范

## 种子数据规则

- 种子数据用于演示和测试
- 必须包含足够的样例数据覆盖各种状态
- 数据要真实合理（中文名称、真实场景）
- 种子脚本放在 `scripts/seed.ts`

## 脚本规范

- 脚本必须先清空现有数据再插入
- 使用事务确保数据一致性
- 执行后输出插入数量统计

## 参考规范

- 种子数据规范：`knowledge-repos/knowledge/general/seed-data-spec.md`
