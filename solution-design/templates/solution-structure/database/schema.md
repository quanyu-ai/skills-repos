# {{PROJECT}} 表结构

> ER 图见 `./er-diagram.md`。本文件维护完整的字段定义、索引、约束。

## 命名规范

- 表名：复数 + 小写下划线（`users`、`order_items`）
- 字段名：小写下划线（`created_at`）
- 主键：`id` bigint auto_increment
- 外键：`<entity>_id`
- 时间戳：`created_at` / `updated_at`（必备）/ `deleted_at`（软删除）

## 表清单

| 表名 | 业务含义 | 行级估算 | 关联模块 |
| --- | --- | --- | --- |
| users | 用户 | _TBD_ | user |
| orders | 订单 | _TBD_ | order |

## 表定义

### users

| 字段 | 类型 | 约束 | 说明 |
| --- | --- | --- | --- |
| id | bigint | PK, auto_increment | 主键 |
| name | varchar(64) | NOT NULL | 姓名 |
| email | varchar(128) | UNIQUE | 邮箱 |
| created_at | datetime | DEFAULT NOW() | 创建时间 |

**索引：** `idx_email (email)`

### orders

_（按相同格式继续）_

## 迁移策略

- 工具：_TBD_（Prisma / Knex / Flyway）
- 命名：`YYYYMMDDHHmm_<description>.sql`
- 回滚：每条 up 必有 down
