# {{PROJECT}} 数据流

> 描述系统内部数据如何在角色 / 模块 / 存储间流动。
> 重要场景每个画一张 mermaid 时序图，避免长篇文字。

## 1. 核心业务时序

```mermaid
sequenceDiagram
    participant U as 用户
    participant F as 前端
    participant G as 网关
    participant B as 后端
    participant D as 数据库
    participant C as 缓存

    U->>F: 1. 操作
    F->>G: 2. API 调用
    G->>B: 3. 转发 + 鉴权
    B->>C: 4. 查缓存
    alt 缓存命中
        C-->>B: 命中数据
    else 缓存缺失
        B->>D: 查数据库
        D-->>B: 数据
        B->>C: 回填缓存
    end
    B-->>F: 响应
    F-->>U: 渲染
```

## 2. 关键场景

### 场景 A：用户登录

- 输入：账号 / 密码
- 处理：用户表查询 → 密码比对 → 签发 JWT
- 输出：token，写入 Redis 黑名单 / 白名单
- 涉及表：users / sessions
- 涉及模块：auth

### 场景 B：_TBD_

_（按相同结构补全）_

## 3. 异步 / 事件流

```mermaid
flowchart LR
    Trigger[触发源] -->|事件| Queue[消息队列]
    Queue --> Worker[消费者]
    Worker --> DB[(写库)]
    Worker --> Notify[通知服务]
```

| 事件 | 生产者 | 消费者 | 频率 | 失败策略 |
| --- | --- | --- | --- | --- |
| _TBD_ | _TBD_ | _TBD_ | _TBD_ | _TBD_ |

## 4. 数据流矩阵

| 来源 | 去向 | 触发 | 频率 | 体积 |
| --- | --- | --- | --- | --- |
| _TBD_ | _TBD_ | _TBD_ | _TBD_ | _TBD_ |

## 5. 关联

- 数据模型详见 [`../database/er-diagram.md`](../database/er-diagram.md)
- 各模块流程见 [`../modules/`](../modules/)
