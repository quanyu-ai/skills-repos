---
name: quanyu-deploy
description: 权舆科技项目部署技能。当任务涉及部署、Docker、演示环境、生产环境、启停服务、构建镜像、docker-compose、Dockerfile、Nginx配置、部署建档、版本发布、git tag、上线时激活。
---

# 权舆科技部署技能

## 核心原则

1. 演示环境 Docker `restart: "no"`，按需启停；生产环境 `restart: unless-stopped`，常驻运行
2. 部署文件放 `/opt/demo/<project>/`，源码不动
3. Monorepo 的 Docker build context 必须指向 monorepo 根目录
4. **部署前代码必须已 commit + push 到 GitHub**
5. 四者版本一致：git tag = package.json = 镜像标签 = DEPLOY-LOG
6. 不确定的事先问项目经理

## 强制约束

### 端口分配规则（绝对禁止随意选端口）
- 新项目端口必须从 `INFRA-LEDGER.md` 的端口分配表中按顺序取用
- 演示环境：3100-3199 范围
- 分配后必须更新 `INFRA-LEDGER.md`
- 禁止使用安全组未开放的端口

### Docker 配置
- `build.context` 指向 monorepo 源码根目录绝对路径，**禁止**临时目录/rsync/build-context 子目录
- 演示 `restart: "no"`，生产 `restart: unless-stopped`
- 资源限制：演示默认 768M/0.5CPU
- 容器命名：演示 `demo-<project>`，生产 `prod-<project>`
- Dockerfile 必须配置 `npm config set registry https://registry.npmmirror.com`
- Next.js 项目 next.config 必须有 `output: 'standalone'`

### 版本管理
- 部署前确认代码已 commit + push
- 查最新 tag → 按变更类型递增 → 更新 package.json → commit → 打 tag → push
- 变更类型由项目经理在任务中指定：修复(补丁+1) / 新功能(次版本+1) / 大改版(主版本+1)
- git tag 格式：`<project>/v<版本号>`（如 `website/v1.1.0`）
- 镜像双标签：`quanyu/<project>:v<版本号>` + `quanyu/<project>:latest`

### 版本递增完整步骤
```bash
# 1. 查当前最新 tag
git tag -l "<project>/*" --sort=-v:refname | head -1

# 2. 更新 package.json
cd apps/<app> && npm version <新版本号> --no-git-tag-version

# 3. commit + push
git add . && git commit -m "release(<project>): v<新版本号>"
git push

# 4. 打 tag + push tag
git tag <project>/v<新版本号>
git push origin <project>/v<新版本号>

# 5. 构建镜像
docker compose build
```

## docker-compose.yml 模板

直接使用，只替换尖括号变量：

```yaml
version: '3.8'

services:
  app:
    build:
      context: <MONOREPO_ROOT_PATH>
      dockerfile: <RELATIVE_DOCKERFILE_PATH>
    image: quanyu/<PROJECT_NAME>:<VERSION>
    container_name: demo-<PROJECT_NAME>
    ports:
      - "<PORT>:3000"
    environment:
      - NODE_ENV=production
    restart: "no"
    deploy:
      resources:
        limits:
          memory: 768M
          cpus: '0.5'
```

## Next.js Dockerfile 模板

```dockerfile
FROM node:18-alpine AS base
WORKDIR /app

RUN npm config set registry https://registry.npmmirror.com && \
    npm install -g pnpm@9.5.0 && \
    pnpm config set registry https://registry.npmmirror.com

COPY package.json pnpm-lock.yaml pnpm-workspace.yaml turbo.json ./
COPY packages/ ./packages/
COPY apps/<APP_NAME>/package.json ./apps/<APP_NAME>/
RUN pnpm install --frozen-lockfile

COPY apps/<APP_NAME>/ ./apps/<APP_NAME>/
COPY tsconfig.base.json ./
WORKDIR /app/apps/<APP_NAME>
RUN pnpm build

FROM node:18-alpine AS runner
WORKDIR /app
ENV NODE_ENV=production
ENV NEXT_TELEMETRY_DISABLED=1
RUN addgroup --system --gid 1001 nodejs && adduser --system --uid 1001 nextjs

COPY --from=base /app/apps/<APP_NAME>/.next/standalone ./
COPY --from=base /app/apps/<APP_NAME>/.next/static ./apps/<APP_NAME>/.next/static
COPY --from=base /app/apps/<APP_NAME>/public ./apps/<APP_NAME>/public

USER nextjs
EXPOSE 3000
ENV PORT=3000
CMD ["node", "apps/<APP_NAME>/server.js"]
```

## 生产迭代部署：数据库变更安全流程

**有数据库 schema 变更时必须执行**：
1. 技术总监审核 migration 脚本
2. **备份生产数据库**
3. 在演示环境用生产数据副本测试 migration
4. 创始人确认
5. 执行 migration → 换镜像 → 验证
6. 异常 → 恢复备份 + 回退镜像

**无数据库变更**：直接换镜像重启。

## 部署完成 = 4步闭环（缺一不可）

```
✅ 第一步：执行部署
   构建镜像 → 启动容器 → 健康检查 → 跑合规检查脚本

✅ 第二步：更新记录
   更新 DEPLOY-LOG.md（版本号、资源占用） + 更新 INFRA-LEDGER.md

✅ 第三步：更新项目进度
   更新 PROJECT-BOARD.md 状态

✅ 第四步：通知项目经理
   汇报：版本号、访问地址、资源占用、是否有异常
```

**遗漏任何一步 = 部署任务未完成。**

## 故障排查原则

**服务异常时，先查日志定位问题，禁止凭猜测归因。**

排查顺序：
1. 确认问题现象
2. `docker compose ps` 查看容器状态
3. `docker compose logs` 查看日志
4. 检查端口、资源、网络
5. 定位原因后再修复
6. 修复后必须验证
7. 记录事故报告（时间、现象、原因、修复方案、预防措施）

## 合规检查

部署完成前运行：
```bash
bash skills/quanyu-deploy/scripts/check-deploy.sh /opt/demo/<project>
```

## 踩坑必读

- PIT-006：Prisma generate
- PIT-009：OpenClaw 就在阿里云上，不需要 SSH
- PIT-010：Monorepo Docker 构建上下文路径
- PIT-011：edit 重试死循环

详见 `knowledge-repos/knowledge/internal/pitfall-registry.md`。
完整规范见 `knowledge-repos/guides/demo-deployment.md`。

## 部署包方案

B端客户交付或新环境部署时，必须构建标准化部署包：

```
deploy-package-<项目名>-v<版本号>.tar.gz
├── README-DEPLOY.md        ← 部署指南
├── docker-compose.yml
├── .env.example
├── images/                 ← docker save 导出的镜像
├── scripts/                ← install/start/stop/backup/health-check
├── nginx/                  ← Nginx 配置模板（如需要）
└── docs/                   ← 环境要求 + 排查手册
```

部署包版本号必须与 git tag、package.json、镜像标签一致。
详见 `knowledge-repos/guides/skeleton-and-repos.md` 第四节。

## 部署后必须清理（2026-05-12 新增）

每次 `docker compose build` 后必须执行清理：
```bash
bash /opt/scripts/deploy-cleanup.sh
```

原因：Node.js 项目构建缓存每次 ~700MB，不清理会吃满磁盘（PIT-043）

## 踩坑必读（新增）

- PIT-020：standalone 部署必须手动复制 Prisma engine + 部署后必须验证 API 通路
- PIT-021：端口必须从 INFRA-LEDGER.md 按顺序取用，禁止随意选
- PIT-043：Docker 构建缓存膨胀导致服务器卡死（2026-05-11事故），已配置 daemon.json 自动GC + 部署后清理脚本

## PM2 部署环境变量检查清单（PIT-046）

部署到 PM2 后，必须确认以下环境变量已注入：

| 变量 | 必需 | 说明 |
|------|------|------|
| DATABASE_URL | ✅ | 数据库连接字符串 |
| PORT | ✅ | 应用监听端口（不能与其他服务冲突） |
| JWT_SECRET | ✅ | JWT 签名密钥 |
| NODE_ENV | ✅ | 设为 production |

### 检查命令
```bash
pm2 env <id> | grep -E "DATABASE_URL|PORT|JWT_SECRET|NODE_ENV"
```

### 端口分配表
| 应用 | 端口 |
|------|------|
| paiji | 3101 |
| cst | 3102 |
| smartops | 3103 |
| qicha | 3104 |

### 踩坑记录
- PIT-046：契查部署后数据不显示，因为 PM2 启动时没传 DATABASE_URL（2026-05-13）
