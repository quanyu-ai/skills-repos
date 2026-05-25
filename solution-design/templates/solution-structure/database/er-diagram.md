# {{PROJECT}} ER 图

> 用 mermaid `erDiagram` 维护实体关系。字段细节见 [`./schema.md`](./schema.md)。

## 全景 ER 图

```mermaid
erDiagram
    USER ||--o{ ORDER : places
    ORDER ||--|{ ORDER_ITEM : contains
    PRODUCT ||--o{ ORDER_ITEM : included-in
    USER ||--o{ SESSION : owns

    USER {
        bigint id PK
        string name
        string email UK
        string status
        datetime created_at
    }
    ORDER {
        bigint id PK
        bigint user_id FK
        decimal total
        string status
        datetime created_at
    }
    PRODUCT {
        bigint id PK
        string name
        decimal price
        int stock
    }
    ORDER_ITEM {
        bigint id PK
        bigint order_id FK
        bigint product_id FK
        int quantity
        decimal unit_price
    }
    SESSION {
        bigint id PK
        bigint user_id FK
        string token
        datetime expires_at
    }
```

## 实体说明

| 实体 | 业务含义 | 主键策略 | 软删除 |
| --- | --- | --- | --- |
| USER | 用户 | 自增 bigint | ✔ |
| ORDER | 订单 | 自增 bigint | ✘（状态机标记） |
| PRODUCT | 商品 | 自增 bigint | ✔ |

## 关键关系

- **USER 1:N ORDER**：一个用户多个订单
- **ORDER 1:N ORDER_ITEM**：一个订单多个明细
- **PRODUCT 1:N ORDER_ITEM**：一个商品出现在多个订单

## 分层 ER（可选）

> 当实体超过 ~20 个时，按域拆分子 ER 图。

### 子域 A：用户 & 鉴权

```mermaid
erDiagram
    USER ||--o{ SESSION : owns
```

### 子域 B：_TBD_
