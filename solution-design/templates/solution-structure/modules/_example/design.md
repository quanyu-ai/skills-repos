# 模块：_example

> 这是示例模块。新建模块时拷贝本目录：
> `cp -r modules/_example modules/<your-module>`

## 1. 模块定位

_（一段话说清这个模块做什么 / 不做什么）_

## 2. 关联 REQ

详见 `./reqs.json`。

## 3. 关键流程

```mermaid
flowchart LR
    Start([开始]) --> Action[动作]
    Action --> End([结束])
```

## 4. 涉及表

| 表名 | 角色 | 备注 |
| --- | --- | --- |
| _TBD_ | _主表 / 关联表_ | _TBD_ |

## 5. API 清单

详见 `./apis.json`。

## 6. 跨模块依赖

| 依赖模块 | 用途 | 协议 |
| --- | --- | --- |
| _TBD_ | _TBD_ | _函数调用 / HTTP / 事件_ |

## 7. 状态机（如有）

_（流程类业务画状态机，简单模块可省略）_

## 8. 关联 ADR

- ADR-NNN: _TBD_

## 9. 测试要点

- _关键路径 1_
- _边界条件_
- _异常处理_
