---
name: quanyu-deploy
description: 权舆科技部署技能。当任务涉及部署、Docker、演示环境、生产环境、启停服务、构建镜像、docker-compose、Dockerfile、Nginx配置、部署建档、版本发布、git tag、上线时激活。
---

# 权舆科技部署技能

## 核心原则

1. 部署统一调用 `/opt/scripts/deploy-app.sh <app-name>`
2. 部署后必须验证服务可用
3. 部署完成后必须清理临时文件

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
- 骨架模板：`knowledge-repos/guides/skeleton-and-repos.md`
