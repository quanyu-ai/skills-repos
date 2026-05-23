# {{PROJECT}} ER 图

> 用 mermaid `erDiagram` 维护实体关系。表结构细节见 `./schema.md`。

```mermaid
erDiagram
    USER ||--o{ ORDER : places
    ORDER ||--|{ ORDER_ITEM : contains
    PRODUCT ||--o{ ORDER_ITEM : included-in

    USER {
        bigint id PK
        string name
        string email
    }
    ORDER {
        bigint id PK
        bigint user_id FK
        decimal total
        datetime created_at
    }
    PRODUCT {
        bigint id PK
        string name
        decimal price
    }
```

## 实体说明

| 实体 | 业务含义 | 主键策略 |
| --- | --- | --- |
| USER | 用户 | 自增 bigint |
| ORDER | 订单 | 自增 bigint |

## 关键关系

- USER 1:N ORDER（一个用户多个订单）
- ORDER 1:N ORDER_ITEM（一个订单多个明细）
