# {{PROJECT}} API 设计

> 风格：_RESTful / tRPC / GraphQL_（在 ADR 中决策）

## 全局约定

- Base URL：`/api/v1`
- 鉴权：`Authorization: Bearer <token>`
- 响应：`{ "code": 0, "data": {}, "msg": "" }`
- 错误码：见 `./error-codes.md`（如有）

## 路由总览

| 模块 | Method | Path | 说明 | 关联 REQ |
| --- | --- | --- | --- | --- |
| auth | POST | /auth/login | 登录 | REQ-XXX |
| auth | POST | /auth/logout | 登出 | REQ-XXX |
| user | GET | /users/:id | 用户详情 | REQ-XXX |
| user | PUT | /users/:id | 更新用户 | REQ-XXX |

## 模块详细 API

各模块的详细 API 文档放在 `../modules/<name>/apis.json` 中维护，本文件只做总览。

## 版本策略

- 路径版本：`/api/v1`、`/api/v2`
- 废弃流程：标记 `deprecated` → 通知期 → 移除
- 关联 ADR：ADR-NNN
