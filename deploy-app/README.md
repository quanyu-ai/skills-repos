# deploy-app — 标准化部署 Skill 🚀

> 把"部署"做成一个可复用、可审计、可回滚的标准流程。主 Agent 不准再手撕 `pm2 / scp / ssh / rsync`，所有部署动作必须通过本 skill 完成。

---

## 项目简介

deploy-app 是 OpenClaw 的标准化部署 Skill，旨在将部署过程变成一个参数化、可审计、可回滚的标准流程。支持三级环境（demo/test/prod），强制自检机制，防止"手撕部署"导致的不可追溯问题。

## 设计理念

### 核心问题

1. **部署不规范**：不同项目有不同的部署脚本和命令
2. **无审计记录**：手动部署无法追踪历史版本和操作人
3. **回滚困难**：出问题时无法快速回退到稳定版本
4. **权限混乱**：直接用 root 或个人账号部署，缺乏权限控制
5. **环境不一致**：演示、测试、生产环境配置未隔离

### 解决方案

- **参数化配置**：`apps.json`（应用元数据）+ `environments.json`（环境参数）
- **强制自检**：`doctor.sh` 在每次部署前验证环境
- **版本化部署**：`releases/` 目录 + `current` symlink，支持一键回滚
- **门禁机制**：prod 环境 5 道门禁，防止误操作
- **权限隔离**：使用 openclaw 用户 + 限定密钥的 SSH 连接

## 能力清单

### 核心功能

- ✅ **标准化部署**：统一的 deploy.sh 接口，支持所有应用
- ✅ **环境隔离**：demo/test/prod 三级环境配置
- ✅ **强制自检**：doctor.sh 每次部署前验证
- ✅ **版本化**：releases/ + current symlink + 自动清理旧版本
- ✅ **回滚**：rollback.sh 一键回退到上一版本
- ✅ **健康检查**：verify.sh 支持宽松/严格双模式
- ✅ **部署锁**：flock 防止并发部署同一应用
- ✅ **配置分层**：environments.json + environments.local.json（deep merge）
- ✅ **自动化日志**：每次部署自动写入 DEPLOY-LOG.md
- ✅ **prod 门禁**：5 道门禁防止生产环境误操作

### 部署模式

- ✅ PM2 模式（默认）
- ⏳ Docker 模式（待 Phase 2.5 实现）
- ⏳ Nginx 静态部署（待 Phase 2.5 实现）

### 支持的框架

- ✅ Next.js
- ✅ Express/NestJS
- ✅ Node.js 原生
- ✅ Static（待实现）

## 架构图

```
┌─────────────────────────────────────────────────────────┐
│                  deploy-app Skill                       │
├─────────────────────────────────────────────────────────┤
│  📚 配置层                                               │
│  - apps.json          (应用元数据，与环境无关)            │
│  - environments.json  (环境参数，三级配置)                │
│  - environments.local.json (本地覆盖，gitignore)         │
│  - schema.md          (配置字段说明)                     │
├─────────────────────────────────────────────────────────┤
│  🛠️  执行层                                               │
│  - scripts/deploy.sh  (10步部署流程)                     │
│    ├─ 配置合并 → 部署锁 → 自检 → 预检查 → git拉取 → 构建   │
│    ├─ 部署 → 健康检查 → 失败回滚 → 写日志                  │
│  - scripts/rollback.sh (版本回滚)                        │
│  - scripts/verify.sh  (健康检查)                         │
│  - scripts/doctor.sh  (6项自检)                         │
│  - scripts/init.sh    (交互式初始化)                     │
├─────────────────────────────────────────────────────────┤
│  📊 审计层                                               │
│  - DEPLOY-LOG.md      (自动记录部署历史)                  │
│  - deploy-locks/      (部署锁文件)                        │
│  - releases/          (版本化产物目录)                     │
└─────────────────────────────────────────────────────────┘
```

## 目录结构

```
/var/lib/openclaw/.openclaw/workspace/skills/deploy-app/
├── SKILL.md                  # 触发入口 + 红线规则
├── README.md                 # 本文档
├── setup.md                  # 首次安装引导
├── doctor.md                 # 自检脚本说明
├── config/
│   ├── apps.json             # 应用元数据注册表
│   ├── apps.json.template    # apps.json 模板
│   ├── environments.json     # 环境配置表
│   ├── environments.json.template  # environments.json 模板
│   ├── environments.local.example  # 本地覆盖示例
│   └── schema.md             # 配置字段说明文档
├── scripts/
│   ├── deploy.sh             # 主部署脚本（723行）
│   ├── rollback.sh           # 回滚脚本（295行）
│   ├── verify.sh             # 健康检查（88行）
│   ├── doctor.sh             # 自检脚本（6项检查）
│   └── init.sh               # 交互式初始化向导
└── templates/                # 预留目录
```

## 参数化使用

### deploy.sh（部署）

```bash
bash scripts/deploy.sh <env> <app> [--version <ref>] [--approved-by <user>] [--skip-build] [--dry-run]
```

| 参数 | 说明 |
|------|------|
| `<env>` | 环境名：`demo` / `test` / `prod` |
| `<app>` | 应用 key（apps.json 中定义） |
| `--version` | 指定 git tag/sha（默认：当前分支 HEAD） |
| `--approved-by` | 审批人（prod 环境必需） |
| `--skip-build` | 跳过构建步骤（用于快速重部署） |
| `--dry-run` | 只打印操作，不实际执行 |

### verify.sh（健康检查）

```bash
bash scripts/verify.sh <env> <app> [--strict]
```

| 参数 | 说明 |
|------|------|
| `--strict` | 严格模式：仅 2xx/3xx 视为健康（默认宽松模式：2xx/3xx/401/403 均视为健康） |

### rollback.sh（回滚）

```bash
bash scripts/rollback.sh <env> <app>
```

回滚到上一个稳定版本。

### doctor.sh（自检）

```bash
bash scripts/doctor.sh
```

输出 `READY` 表示可以部署，`NEED_SETUP` 表示需要先执行 setup.md。

### init.sh（初始化）

```bash
bash scripts/init.sh
```

交互式向导，帮助生成 apps.json 和 environments.json 草稿。

## 配置说明

### apps.json（应用元数据）

记录应用本身的信息，与环境无关：

```json
{
  "apps": {
    "quanyu-console": {
      "display_name": "权舆系统展示控制台",
      "project_path": "/var/lib/openclaw/.openclaw/workspace/code-repos/quanyu-console",
      "repo_url": "git@github.com:quanyu-ai/quanyu-console.git",
      "build_cmd": "pnpm install --frozen-lockfile && pnpm build",
      "start_cmd": "pnpm start",
      "health_path": "/api/health",
      "framework": "nextjs"
    }
  }
}
```

### environments.json（环境配置）

记录环境 × 应用的部署参数：

```json
{
  "environments": {
    "demo": {
      "host": "localhost",
      "ssh_user": "openclaw",
      "ssh_key": "~/.ssh/deploy_local",
      "deploy_mode": "pm2",
      "deploy_root": "/var/lib/openclaw/deploy-demo",
      "releases_to_keep": 3,
      "use_https_cookies": false,
      "node_env": "production",
      "apps": {
        "quanyu-console": { "port": 3101, "pm2_name": "quanyu-console" }
      }
    },
    "prod": {
      "default_host": "43.139.53.121",
      "ssh_user": "ubuntu",
      "ssh_key": "~/.ssh/deploy_prod",
      "deploy_mode": "pm2",
      "deploy_root": "/var/lib/openclaw/deploy-prod",
      "releases_to_keep": 5,
      "use_https_cookies": true,
      "node_env": "production"
    }
  }
}
```

### environments.local.json（本地覆盖）

本地机器的个性化配置，会合并到 environments.json 之上：

```json
{
  "environments": {
    "demo": {
      "ssh_key": "~/.ssh/deploy_local_my_machine"
    }
  }
}
```

**优先级**：`environments.local.json` > `environments.json`

**注意**：该文件已被 gitignore，不会进入版本控制。

## 部署门禁（prod 环境）

prod 环境有 5 道门禁，必须全部通过才能部署：

1. **必须指定版本**：--version 参数不能为空
2. **语义化 tag**：必须是 v*.*.* 格式
3. **tag 存在**：git rev-parse 验证 tag 真实存在
4. **审批人**：--approved-by 参数必须是授权用户（longge/龙哥/dengyunlong）
5. **demo 先行**：该版本必须已在 demo 环境部署过（检查 DEPLOY-LOG.md）

## 版本化部署

当配置了 `deploy_root` 时，部署流程会：

1. 构建产物复制到 `releases/<sha>/` 目录
2. 原子切换 `current` symlink 指向新版本
3. PM2 reload 读取新的 cwd
4. 自动清理旧版本（保留 releases_to_keep 个）

```
<deploy_root>/<app>/
├── current -> releases/abc123
└── releases/
    ├── abc123/  (当前版本)
    ├── def456/  (上一版本)
    └── ghi789/  (更旧版本)
```

## 与其他系统的关系

| 系统 | 关系 |
|------|------|
| `knowledge-repos/management/DEPLOY-LOG.md` | 每次部署自动写入一条记录 |
| `knowledge-repos/management/INFRA-LEDGER.md` | 记录服务器资源、端口分配、域名管理 |
| `daidai-guardrail 插件` | 硬拦截主Agent 直接部署，强制通过 deploy-app skill |
| `AGENTS.md` | 明确主Agent 调度角色，禁止直接写代码/部署 |

## Phase 路线图

| 阶段 | 状态 | 功能 |
|------|------|------|
| **Phase 1** | ✅ 完成 | 框架 + 自检 + 配置模板 + setup 引导 |
| **Phase 2** | ✅ 完成 | 实现 deploy.sh / verify.sh / rollback.sh 主逻辑 |
| **Phase 3** | ✅ 完成 | 版本化部署 + 自动回滚 + 健康检查 |
| **Phase 4** | ✅ 完成 | prod 门禁 + 部署锁 + 分层配置 |
| **Phase 5** | ⏳ 待实现 | Docker 部署模式 |
| **Phase 6** | ⏳ 待实现 | Nginx 静态部署模式 |

## 已知限制

- ❌ Docker 部署模式未实现
- ❌ Nginx 静态部署模式未实现
- ❌ git ls-remote tag 验证待做（当前仅本地 git rev-parse）
- ❌ 增量部署支持待实现

## 维护人

- 主要：龙哥（邓云龙）
- AI 调度：呆呆
- 文档：本 README.md 和 setup.md

---

## 快速启动

1. 首次使用：阅读 `setup.md` 完成初始化
2. 检查环境：`bash scripts/doctor.sh`
3. 部署应用：`bash scripts/deploy.sh demo quanyu-console`
4. 健康检查：`bash scripts/verify.sh demo quanyu-console`
5. 回滚：`bash scripts/rollback.sh demo quanyu-console`