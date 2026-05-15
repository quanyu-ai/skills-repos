---
name: quanyu-seed
description: 权舆科技样板数据编写规范。当任务涉及创建演示数据、种子数据、seed脚本、样板数据时激活。
---

# 样板数据编写规范

## Prisma Client 路径
- 统一使用：`node_modules/.pnpm/@prisma+client@5.22.0_prisma@5.22.0/node_modules/.prisma/client`
- 基于项目根目录的相对路径

## 数据库连接
- DATABASE_URL 从项目 `.env` 文件获取
- 当前连接：`postgresql://quanyu:quanyu_dev_2026@localhost:5432/quanyu_paiji?schema=public`

## 脚本编写规范
1. 写成独立的 `.js` 文件放在 `/tmp/` 下执行
2. 脚本内直接 require PrismaClient，不依赖项目构建
3. 每个表的数据用 `Promise.all` 批量创建，减少数据库往返
4. 脚本末尾打印汇总信息（创建了多少条数据）
5. 异常时打印错误并 `process.exit(1)`

## 数据设计原则
- 覆盖所有枚举值（每个 enum 至少有 1 条数据）
- 覆盖所有状态分支（如 DRAFT/ACTIVE/EXPIRED 等）
- 使用真实自然的中文内容
- 金额/日期在合理范围内
- 关联关系正确（外键对应真实存在的记录）
- 数量适中（每个表 5-15 条，够演示即可）

## 禁止事项
- 禁止让子 Agent 去"探索数据库结构"——主 Agent 提前分析好，把 schema 要点内联到任务描述
- 禁止在脚本中动态查询 schema——直接写死字段名和类型
