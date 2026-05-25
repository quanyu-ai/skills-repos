# {{PROJECT}} API 设计

> 风格选型在 ADR 里决策。本文件维护**总览**，模块细节在 `../modules/<name>/apis.json`。

## 1. 全局约定

| 项 | 值 | 备注 |
| --- | --- | --- |
| 风格 | _RESTful / tRPC / GraphQL_ | 见 ADR-NNN |
| Base URL | `/api/v1` | 路径版本 |
| 鉴权 | `Authorization: Bearer <token>` | JWT；见 ADR-NNN |
| 响应包装 | `{ code, data, msg, trace_id }` | code=0 表示成功 |
| 错误码 | 见 [`./error-codes.md`](./error-codes.md)（如存在） | 业务错 4xxx；系统错 5xxx |
| 时间格式 | ISO-8601 UTC | `2026-05-25T10:00:00Z` |
| 分页 | `?page=1&page_size=20`，响应 `{total, data:[]}` | 上限 100 |
| 幂等 | POST 写操作支持 `Idempotency-Key` 头 | 24h 有效 |

## 2. 路由总览（精选）

| 模块 | Method | Path | 说明 | 鉴权 | 关联 REQ |
| --- | --- | --- | --- | --- | --- |
| auth | POST | /auth/login | 登录 | 无 | REQ-XXX |
| auth | POST | /auth/logout | 登出 | 必须 | REQ-XXX |
| auth | POST | /auth/refresh | Token 刷新 | 必须 | REQ-XXX |
| user | GET | /users/me | 当前用户信息 | 必须 | REQ-XXX |
| user | PUT | /users/:id | 更新用户 | 必须 | REQ-XXX |

> 完整 API 清单：运行 `bash skills/solution-design/scripts/sync-solution-map.sh <project>` 后查看 `solution-map.json` 的 `modules[].apis`。

## 3. 错误码示意

| code | 含义 | HTTP | 处理建议 |
| --- | --- | --- | --- |
| 0 | 成功 | 200 | - |
| 4001 | 参数错误 | 400 | 前端校验提示 |
| 4010 | 未认证 | 401 | 跳登录 |
| 4030 | 无权限 | 403 | 提示用户 |
| 4040 | 资源不存在 | 404 | - |
| 5000 | 系统内部错误 | 500 | 提示+上报 |

## 4. 版本策略

- 路径版本：`/api/v1`、`/api/v2`，破坏性变更才升大版本
- 字段废弃流程：标 `deprecated` → 文档通知期 ≥ 30 天 → 移除
- 灰度新版本通过 Header `X-API-Version` 切换（如有）

## 5. 关联 ADR

- ADR-NNN：API 风格选型
- ADR-NNN：鉴权方案
- ADR-NNN：错误码体系
