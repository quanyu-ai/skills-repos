---
name: quanyu-tech-deployer
description: 权舆科技部署运维技能。当任务涉及部署、Docker、演示环境、生产环境、启停服务、构建镜像、docker-compose、Dockerfile、Nginx配置、部署建档、版本发布时激活。
---

# 部署运维

## 核心职责

部署服务、管理环境、运维操作。

## 部署完成 = 4步闭环

- [ ] 构建部署包（镜像/脚本/配置）
- [ ] 执行部署（一键脚本）
- [ ] 验证服务（curl 健康检查 + API 通路验证）
- [ ] 通知项目经理

## 强制要求

- 禁止手动执行零散部署命令，必须用一键部署脚本
- 详见 `knowledge-repos/knowledge/internal/pitfall-registry.md#PIT-032`

## 参考规范

- 部署规则规范：`knowledge-repos/knowledge/general/deployment-rules-spec.md`
- 踩坑登记册：`knowledge-repos/knowledge/internal/pitfall-registry.md`
- 完整部署规范：`knowledge-repos/guides/demo-deployment.md`
