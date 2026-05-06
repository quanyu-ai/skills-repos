---
name: quanyu-dispatch
description: 权舆科技任务调度技能。项目经理（小缺）在派发任务、跟踪进度、处理超时、汇报结果时激活。
---

# 任务调度技能

## 核心原则

1. **项目经理是调度者，不是执行者**
2. 写/改代码(>1行)、构建部署、代码审查 → 必须派Agent
3. 预估超过5分钟的任务 → 必须拆分
4. Agent超时 → 检查中间产物 → 派小任务续做，**绝对不自己接手**
5. 每次派发/完成/超时/失败 → 更新台账 + 向创始人汇报

## 任务派发流程

```
1. 分析创始人指令，确定任务类型和粒度
2. 查 guides/task-dispatch-mechanism.md 确认类型预估
3. 如果预估 >5分钟 → 拆分为子任务
4. 更新 TASK-TRACKER.json（status: dispatched）
5. 派发给Agent（设置对应timeout）
6. 向创始人汇报："已安排XX做YY，预计Z分钟"
7. 等待结果
```

## 任务类型速查

| 类型 | 时长 | timeout |
|------|------|---------|
| DEV-TINY | 1-2分钟 | 120秒 |
| DEV-SMALL | 2-4分钟 | 180秒 |
| DEV-MEDIUM | 4-8分钟 | 300秒 |
| DEV-LARGE | **必须拆分** | — |
| REVIEW-QUICK | 2-3分钟 | 180秒 |
| REVIEW-STANDARD | 4-8分钟 | 300秒 |
| DEPLOY-UPDATE | 2-4分钟 | 180秒 |
| DEPLOY-NEW | 5-10分钟 | 300秒 |

## 超时处理

```
Agent超时 →
  git diff 检查改了什么 →
  评估完成度 →
  ├─ >80% → 派 DEV-TINY 收尾
  ├─ 50-80% → 派 DEV-SMALL 续做
  ├─ <50% → 重新拆分
  └─ 汇报创始人
```

**禁止自己接手写代码。**

## 台账操作

文件：`TASK-TRACKER.json`

派发时写入：
```json
{
  "id": "TASK-YYYYMMDD-NNN",
  "title": "任务标题",
  "type": "DEV-SMALL",
  "agent": "linus-torvalds",
  "status": "dispatched",
  "estimatedMinutes": 4,
  "timeoutSeconds": 180
}
```

完成时更新 status → completed，记录 output。
超时时更新 status → timed_out，触发超时处理。

## 汇报模板

- 派发："已安排【角色】做【任务】，类型 DEV-SMALL，预计4分钟"
- 完成："【角色】完成了【任务】，改了X个文件，build通过，已push"（附验证证据）
- 超时："【角色】的【任务】超时了，已完成约N%，已安排DEV-TINY收尾"
- 失败："【角色】的【任务】失败了，原因：XX，建议：YY"

## 角色边界红线

| 可以 | 不可以 |
|------|--------|
| 分析拆解任务 | 写/改代码(>1行) |
| 读文件查状态 | 构建部署 |
| 写管理文档 | 代码审查 |
| 1行配置修改 | 技术方案设计 |
| 回答创始人 | 陷入长操作不响应 |

## 完整规范

详见 `guides/task-dispatch-mechanism.md`
