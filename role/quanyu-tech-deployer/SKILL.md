---
name: quanyu-tech-deployer
description: 权舆科技部署运维技能。当任务涉及部署、Docker、PM2、演示环境、测试环境、生产环境、启停服务、构建镜像、docker-compose、Dockerfile、Nginx配置、部署建档、版本发布、原型部署时激活。
---

# 部署运维 v4.0

## 核心职责

部署服务、管理环境、运维操作。

## 部署完成 = 4步闭环

- [ ] 构建部署（PM2/Docker/静态文件）
- [ ] 配置 Nginx 统一反代
- [ ] 验证服务（curl 健康检查 + API 通路验证 + 域名访问）
- [ ] 更新台账 + 通知项目经理

## 核心架构原则（v4.0）

采用 **分层部署策略**，不再强制全 Docker：

| 部署方式 | 优先使用场景 | 避免使用场景 |
|---------|------------|------------|
| **PM2 直接部署** | ✅ 演示环境（首选）<br>✅ Node.js 后端生产<br>✅ 需要频繁发布的项目 | ❌ 非 Node.js 项目<br>❌ 需要强隔离的客户项目 |
| **Docker 容器** | 🟡 测试环境（备选）<br>🟡 客户定制项目<br>🟡 非 Node.js 项目 | ❌ 演示环境（太笨重，内存不足） |
| **Nginx 静态文件** | ✅ 原型部署<br>✅ 纯前端 SPA | ❌ 动态后端服务 |

> 🎯 **统一入口原则**：无论内部用 PM2 还是 Docker，对外统一通过 Nginx 反代访问

## 强制要求

1. **演示环境优先用 PM2**：省内存、构建快、避免 OOM 超时
2. **禁止手动执行零散部署命令**，必须用一键部署脚本
3. **端口必须登记**：从 `INFRA-LEDGER.md` 按顺序取用
4. **Nginx 必须配置**：所有对外访问统一通过域名反代
5. **部署必须验证**：本地 + 域名双重验证通过才算完成

## 部署方式选择决策树

```
开始部署
    │
    ├─ 是原型吗？ → Nginx 静态文件 ✅
    │
    ├─ 是纯前端吗？ → Nginx 静态文件 ✅
    │
    └─ 是 Node.js 项目？
        │
        ├─ 演示环境？ → PM2 ✅（优先）
        │   └─ 需要强隔离？ → Docker 🟡（备选）
        │
        ├─ 测试环境？ → PM2 ✅（优先）
        │   └─ 需验证 Docker 部署？ → Docker 🟡
        │
        └─ 生产环境？
            ├─ Node.js 后端 → PM2 ✅（晨曦模式）
            ├─ 客户定制项目 → Docker ✅
            └─ 其他情况 → 技术总监评估
```

## 标准化脚本体系

### 全局脚本（/opt/scripts/）

| 脚本 | 功能 | 适用场景 |
|------|------|---------|
| **deploy-app.sh** | 核心部署（构建 + 静态资源复制 + Prisma + PM2） | 单纯部署代码，不需要版本管理 |
| **release.sh** | 完整发布流程（Git检查 → 数据库迁移 → 部署 → 版本标记 → 日志记录） | 正式发布新版本 |
| **rollback.sh** | 回滚流程（Git版本切换 → 部署 → 验证 → 日志记录） | 发布出问题时快速回滚 |

### 项目本地脚本（项目目录）

| 脚本 | 功能 | 部署方式 |
|------|------|---------|
| **deploy-pm2.sh** | PM2 一键部署（git pull → 构建 → 启动/重载） | PM2 |
| **start.sh / stop.sh / status.sh** | Docker 容器启停和状态查看 | Docker |
| **deploy-prototype.sh** | 原型静态文件部署 + Nginx 配置 | Nginx 静态文件 |
| **verify.sh** | 部署验证脚本（端口 + 本地访问 + 域名访问） | 所有方式 |

### 使用方式

```bash
# PM2 方式部署演示项目（推荐）
bash guides/scripts/deployment/deploy-pm2.sh <项目名> demo <端口>

# 发布（自动生成版本号）
bash /opt/scripts/release.sh <项目名>

# 发布（指定版本号）
bash /opt/scripts/release.sh <项目名> v1.2.0

# 回滚到指定版本
bash /opt/scripts/rollback.sh <项目名> v1.1.9

# 原型部署
bash guides/scripts/deployment/deploy-prototype.sh <项目名> <html文件路径>
```

### 端口分配表（阿里云）

| 端口范围 | 用途 | 已分配 |
|---------|------|--------|
| 3100-3199 | 演示环境（PM2优先） | 3100=官网, 3101=拍记, 3102=智财, 3103=智策 |
| 3300-3399 | 测试环境 | 待分配 |

> ✅ 新项目分配端口时，必须从 `knowledge-repos/management/INFRA-LEDGER.md` 按顺序取用
> ⚠️ **端口号管理核心原则：端口号一旦分配，永不回收。服务器资源不足时停止服务释放内存，但不要清除端口号。只有当整个项目在 PROJECT-BOARD.md 中标记为删除状态时，才可以考虑释放端口。**

## 部署验证标准（必须全部通过）

- [ ] **进程状态**：`pm2 status` 或 `docker compose ps` 显示正常
- [ ] **端口监听**：`netstat -tlnp | grep <端口>` 正常
- [ ] **本地健康检查**：`curl http://localhost:<port>/` 返回 200
- [ ] **Nginx 反代验证**：通过域名可正常访问
- [ ] **核心功能**：登录、数据增删改查正常
- [ ] **日志检查**：无 ERROR 级别的错误日志

## Docker 注意事项（尽量避免在演示环境使用）

如必须使用 Docker，必须满足：
- 使用多阶段构建，镜像体积控制在 300MB 以内
- 构建前清理缓存：`docker builder prune -af`
- 构建时限制内存：`docker build --memory=1g`

## 参考规范

- 🌟 **完整部署规范 v4.0**：`knowledge-repos/guides/deployment-standard.md`
- 踩坑登记册：`knowledge-repos/knowledge/internal/pitfall-registry.md`
- 基础设施台账：`knowledge-repos/management/INFRA-LEDGER.md`
- 部署日志：`knowledge-repos/management/DEPLOY-LOG.md`
