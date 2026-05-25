# {{PROJECT}} 数据库表结构

> 完整字段、索引、约束定义。
> ER 图见 [`./er-diagram.md`](./er-diagram.md)。

## 命名规范

- **表名**：复数 + 小写下划线（`users`、`order_items`）
- **字段名**：小写下划线（`created_at`、`is_active`）
- **主键**：`id` bigint auto_increment（或 UUID/雪花，在 ADR 决策）
- **外键**：`<entity>_id`，名称对应被关联表的单数
- **时间戳**：`created_at` / `updated_at` 必备；`deleted_at` 用于软删除
- **枚举**：用 varchar 存值，业务层维护取值集合（不用 ENUM 类型）
- **JSONB**：仅用于"非检索"的可扩展配置；需检索的字段抽出独立列

## 表清单

| 表名 | 业务含义 | 行级估算 | 关联模块 | 备注 |
| --- | --- | --- | --- | --- |
| users | 用户 | _TBD_ | user, auth | _TBD_ |
| orders | 订单 | _TBD_ | order | _TBD_ |

## 表定义

### users — 用户

| 字段 | 类型 | 约束 | 说明 |
| --- | --- | --- | --- |
| id | bigint | PK, auto_increment | 主键 |
| name | varchar(64) | NOT NULL | 姓名 |
| email | varchar(128) | UNIQUE, NOT NULL | 邮箱 |
| password_hash | varchar(128) | NOT NULL | 密码哈希（bcrypt） |
| status | varchar(16) | NOT NULL, DEFAULT 'active' | 状态枚举 |
| created_at | datetime | DEFAULT NOW() | 创建时间 |
| updated_at | datetime | ON UPDATE NOW() | 更新时间 |
| deleted_at | datetime | NULL | 软删除时间 |

**索引：**
- `uk_email (email)` 唯一
- `idx_status_created (status, created_at)` 复合

**约束：** email 必须符合标准格式（业务层校验）

### orders — 订单

_（按相同格式继续填写）_

## 迁移策略

| 项 | 选型 | 备注 |
| --- | --- | --- |
| 工具 | _TBD_（Prisma / Knex / Flyway） | _见 ADR-NNN_ |
| 命名 | `YYYYMMDDHHmm_<description>.sql` | 时间戳前缀确保顺序 |
| 回滚 | 每条 up 必有 down | _TBD_ |
| 数据迁移 | 与 schema 迁移分开脚本 | _TBD_ |

## 关联 ADR

- ADR-NNN：数据库选型
- ADR-NNN：迁移工具选型
- ADR-NNN：软删除策略
