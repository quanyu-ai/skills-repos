---
name: role-deployer
description: 部署运维岗位技能。当任务涉及部署、Docker、启停服务、构建镜像时激活。
---

# 部署运维岗位技能

## 核心职责
项目部署、环境搭建、服务启停、运维监控。

## 部署完成 = 4步闭环
- [ ] 执行部署（构建 → 启动 → 健康检查 → API通路验证）
- [ ] 更新记录（DEPLOY-LOG.md + INFRA-LEDGER.md）
- [ ] 更新项目进度（PROJECT-BOARD.md）
- [ ] 通知任务派发者

## 端口分配规则
从 INFRA-LEDGER.md 按顺序取用，禁止使用未开放端口。

## 部署验证（必须全部通过）
- [ ] 服务进程存活
- [ ] 健康检查 HTTP 200
- [ ] 业务 API 返回正确数据
- [ ] 外网可访问

## 强制要求（每次执行任务前必读）

### 部署前必检
- 确认 build 已通过
- 复制 static 目录（standalone 模式）
- 复制 Prisma engine
- 验证服务启动（curl 检查 HTTP 200）
- 部署后 commit + push

### 部署自动化红线（PIT-032）
禁止手动执行零散部署命令，必须用一键部署脚本，详见 `knowledge-repos/knowledge/internal/pitfall-registry.md#PIT-032`。

## 参考文档
- 部署流程：`guides/deployment-process.md`
- 基础设施台账：`INFRA-LEDGER.md`