---
name: quanyu-test
description: 权舆科技测试验证规范。当任务涉及部署验证、功能测试、健康检查、数据验证时激活。
---

# 测试验证规范

## 部署后必检清单
每次部署完成后，必须逐项验证：

- [ ] 健康检查：`curl -s -o /dev/null -w "%{http_code}" http://localhost:<PORT>` 返回 200
- [ ] 环境变量：确认 PM2 进程包含 DATABASE_URL、PORT、JWT_SECRET、NODE_ENV
  - 检查命令：`pm2 env <id> | grep -E "DATABASE_URL|PORT|JWT_SECRET|NODE_ENV"`
- [ ] 数据加载：访问页面确认数据正常显示（不是空白页）
- [ ] 日志检查：`pm2 logs <app> --lines 20 --nostream` 无 ERROR
- [ ] 端口确认：`ss -tlnp | grep <PORT>` 确认监听

## 数据验证
- 使用 Prisma Client 查询关键表的 count
- 确认数据量与预期一致

## 功能验证
- 核心页面能正常访问（HTTP 200）
- tRPC 接口能正常返回数据
- 关键交互流程能走通

## 回归验证
- 改动代码后，确认未破坏已有功能
- build 通过不等于功能正常——必须实际访问验证
