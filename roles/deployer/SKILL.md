---
name: role-deployer
description: 部署运维岗位技能。当任务涉及部署、Docker、启停服务、构建镜像时激活。
---

# 部署运维岗位技能

## 职责

项目部署、环境搭建、服务启停、运维监控。

## 部署完成 = 4步闭环（缺一不可）

```
✅ 第一步：执行部署
   构建镜像/build → 启动服务 → 健康检查 → API通路验证

✅ 第二步：更新记录
   更新 DEPLOY-LOG.md + INFRA-LEDGER.md

✅ 第三步：更新项目进度
   更新 PROJECT-BOARD.md 状态

✅ 第四步：通知任务派发者
   汇报：版本号、访问地址、资源占用、是否有异常
```

## 端口分配规则

- 从 `INFRA-LEDGER.md` 的端口分配表中按顺序取用
- 禁止使用安全组未开放的端口
- 分配后必须更新台账

## 部署验证（必须全部通过才算完成）

- [ ] 服务进程存活
- [ ] 健康检查 HTTP 200
- [ ] 至少一个业务 API 返回正确数据
- [ ] 外网可访问（如适用）

## 环境分类

| 环境 | 容器restart策略 | 命名 |
|------|----------------|------|
| 演示 | `restart: "no"` | `demo-<project>` |
| 生产 | `restart: unless-stopped` | `prod-<project>` |

## 故障排查

先查日志定位问题，禁止凭猜测归因。排查顺序：
1. 确认现象 → 2. 查容器状态 → 3. 查日志 → 4. 检查端口/资源/网络 → 5. 定位修复 → 6. 验证 → 7. 记录事故报告

## 强制要求（每次执行任务前必读）

### 部署前必检
1. **确认 build 已通过**：不接受未 build 的代码部署
2. **复制 static 目录**：standalone 模式必须复制 `.next/static`
3. **复制 Prisma engine**：必须复制 `libquery_engine-*.so.node` + `schema.prisma`
4. **验证服务启动**：部署后必须 `curl` 检查 HTTP 200
5. **commit + push**：部署成功后必须提交并推送

### 部署脚本
- 拍记：`bash scripts/deploy-paiji.sh`
- 财税通：`bash scripts/deploy-cst.sh`（如不存在需先创建）
- **禁止手动执行零散的部署命令**，必须用脚本

### 端口分配
| 项目 | 端口 |
|------|------|
| 官网 | 3100 |
| 拍记 | 3101 |
| 财税通 | 3102 |

### 部署自动化红线（PIT-032）
- **禁止手动执行零散部署命令**（手动复制 static、手动复制 Prisma engine 等）
- 每个项目必须有 `scripts/deploy-<项目>.sh` 一键部署脚本
- 脚本必须包含：build + 复制 static + 复制 Prisma engine + 重启服务 + 验证 HTTP 200
