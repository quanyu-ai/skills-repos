# deploy-app - 标准化部署 Skill 🚀

> 把"部署"做成一个可复用、可审计、可回滚的标准流程。主 Agent 不准再手撕 `pm2 / scp / ssh / rsync`,所有部署动作必须通过本 skill 完成。

---

## 项目简介

deploy-app 是 OpenClaw 的标准化部署 Skill,旨在将部署过程变成一个参数化、可审计、可回滚的标准流程。支持四级环境(proto/test/demo/prod),强制自检机制,防止"手撕部署"导致的不可追溯问题。

## 设计理念

### 核心问题

1. **部署不规范**:不同项目有不同的部署脚本和命令
2. **无审计记录**:手动部署无法追踪历史版本和操作人
3. **回滚困难**:出问题时无法快速回退到稳定版本
4. **权限混乱**:直接用 root 或个人账号部署,缺乏权限控制
5. **环境不一致**:演示、测试、生产环境配置未隔离

### 解决方案

- **参数化配置**:`apps.json`(应用元数据)+ `environments.json`(环境参数)
- **强制自检**:`doctor.sh` 在每次部署前验证环境
- **版本化部署**:`releases/` 目录 + `current` symlink,支持一键回滚
- **门禁机制**:prod 环境 5 道门禁,防止误操作
- **权限隔离**:使用 openclaw 用户 + 限定密钥的 SSH 连接

## 能力清单

### 核心功能

- ✅ **标准化部署**:统一的 deploy.sh 接口,支持所有应用
- ✅ **环境隔离**:proto/test/demo/prod 四级环境配置
- ✅ **强制自检**:doctor.sh 每次部署前验证
- ✅ **版本化**:releases/ + current symlink + 自动清理旧版本
- ✅ **回滚**:rollback.sh 一键回退到上一版本
- ✅ **健康检查**:verify.sh 支持宽松/严格双模式
- ✅ **环境差异化配置**:apps.json 支持 env_config,按环境覆盖框架/命令等配置
- ✅ **端口变化检测**:自动检测端口变化,执行 delete+start 而非 reload
- ✅ **原型部署**:支持 static 框架快速部署,无需构建
- ✅ **部署锁**:flock 防止并发部署同一应用
- ✅ **配置分层**:environments.json + environments.local.json(deep merge)
- ✅ **自动化日志**:每次部署自动写入 DEPLOY-LOG.md
- ✅ **prod 门禁**:5 道门禁防止生产环境误操作

### 部署模式

- ✅ PM2 模式(默认)
- ⏳ Docker 模式(待 Phase 2.5 实现)
- ⏳ Nginx 静态部署(待 Phase 2.5 实现)

### 支持的框架

- ✅ Next.js
- ✅ Express/NestJS
- ✅ Node.js 原生
- ✅ Static(待实现)

## 架构图

```
┌─────────────────────────────────────────────────────────┐
│                  deploy-app Skill                       │
├─────────────────────────────────────────────────────────┤
│  📚 配置层                                               │
│  - apps.json          (应用元数据,与环境无关)            │
│  - environments.json  (环境参数,三级配置)                │
│  - environments.local.json (本地覆盖,gitignore)         │
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
│   ├── deploy.sh             # 主部署脚本(723行)
│   ├── rollback.sh           # 回滚脚本(295行)
│   ├── verify.sh             # 健康检查(88行)
│   ├── doctor.sh             # 自检脚本(6项检查)
│   └── init.sh               # 交互式初始化向导
└── templates/                # 预留目录
```

## 参数化使用

### deploy.sh(部署)

```bash
bash scripts/deploy.sh <env> <app> [--version <ref>] [--approved-by <user>] [--skip-build] [--dry-run]
```

| 参数 | 说明 |
|------|------|
| `<env>` | 环境名:`proto` / `test` / `demo` / `prod` |
| `<app>` | 应用 key(apps.json 中定义) |
| `--version` | 指定 git tag/sha(默认:当前分支 HEAD) |
| `--approved-by` | 审批人(prod 环境必需) |
| `--skip-build` | 跳过构建步骤(用于快速重部署) |
| `--dry-run` | 只打印操作,不实际执行 |

### verify.sh(健康检查)

```bash
bash scripts/verify.sh <env> <app> [--strict]
```

| 参数 | 说明 |
|------|------|
| `--strict` | 严格模式:仅 2xx/3xx 视为健康(默认宽松模式:2xx/3xx/401/403 均视为健康) |

### rollback.sh(回滚)

```bash
bash scripts/rollback.sh <env> <app>
```

回滚到上一个稳定版本。

### doctor.sh(自检)

```bash
bash scripts/doctor.sh
```

输出 `READY` 表示可以部署,`NEED_SETUP` 表示需要先执行 setup.md。

### init.sh(初始化)

```bash
bash scripts/init.sh
```

交互式向导,帮助生成 apps.json 和 environments.json 草稿。

## 配置说明

### apps.json(应用元数据)

记录应用本身的信息,与环境无关。支持 `env_config` 字段,按环境覆盖配置:

```json
{
  "apps": {
    "smart-college-prototype": {
      "display_name": "智能学院原型",
      "project_path": "/var/lib/openclaw/.openclaw/workspace/docs-repos/smart-college/prototype",
      "repo_url": "",
      "build_cmd": "",
      "start_cmd": "node server.js",
      "health_path": "/",
      "framework": "static",
      "env_config": {
        "proto": {
          "display_name": "原型智能学院",
          "framework": "static",
          "start_cmd": "node server.js"
        },
        "test": {
          "display_name": "测试智能学院",
          "framework": "static",
          "start_cmd": "node server.js"
        },
        "demo": {
          "display_name": "演示智能学院",
          "framework": "static",
          "start_cmd": "node server.js"
        },
        "prod": {
          "display_name": "生产智能学院",
          "framework": "static",
          "start_cmd": "node server.js"
        }
      }
    }
  }
}
```

**env_config 优先级**:`env_config.<env>` > 全局配置

**支持覆盖的字段**:display_name, framework, build_cmd, start_cmd, health_path 等

### environments.json(环境配置)

记录环境 × 应用的部署参数。支持四环境号段:

| 环境 | 号段 | 用途 |
|------|------|------|
| **proto** | 3000-3099 | 原型部署,快速验证 |
| **test** | 3100-3199 | 功能/集成测试 |
| **demo** | 3200-3299 | 对外展示/客户演示 |
| **prod** | 3900-3999 | 生产环境 |

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

### environments.local.json(本地覆盖)

本地机器的个性化配置,会合并到 environments.json 之上:

```json
{
  "environments": {
    "demo": {
      "ssh_key": "~/.ssh/deploy_local_my_machine"
    }
  }
}
```

**优先级**:`environments.local.json` > `environments.json`

**注意**:该文件已被 gitignore,不会进入版本控制。

## 部署门禁(prod 环境)

prod 环境有 5 道门禁,必须全部通过才能部署:

1. **必须指定版本**:--version 参数不能为空
2. **语义化 tag**:必须是 v*.*.* 格式
3. **tag 存在**:git rev-parse 验证 tag 真实存在
4. **审批人**:--approved-by 参数必须是授权用户(longge/龙哥/dengyunlong)
5. **demo 先行**:该版本必须已在 demo 环境部署过(检查 DEPLOY-LOG.md)

## 版本化部署

当配置了 `deploy_root` 时,部署流程会:

1. 构建产物复制到 `releases/<sha>/` 目录
2. 原子切换 `current` symlink 指向新版本
3. PM2 reload 读取新的 cwd
4. 自动清理旧版本(保留 releases_to_keep 个)

```
<deploy_root>/<app>/
├── current -> releases/abc123
└── releases/
    ├── abc123/  (当前版本)
    ├── def456/  (上一版本)
    └── ghi789/  (更旧版本)
```

## 原型部署

proto 环境专为原型部署优化:

- **静态站点**:无需构建,直接部署
- **轻量级**:256MB 内存限制,单实例
- **快速响应**:跳过 git 拉取和构建步骤
- **端口段**:3000-3099

```bash
# 部署原型
bash scripts/deploy.sh proto smart-college-prototype

# 访问
open http://localhost:3021
```

## 与其他系统的关系

| 系统 | 关系 |
|------|------|
| `knowledge-repos/management/DEPLOY-LOG.md` | 每次部署自动写入一条记录 |
| `knowledge-repos/management/INFRA-LEDGER.md` | 记录服务器资源、端口分配、域名管理 |
| `daidai-guardrail 插件` | 硬拦截主Agent 直接部署,强制通过 deploy-app skill |
| `AGENTS.md` | 明确主Agent 调度角色,禁止直接写代码/部署 |

## Phase 路线图

| 阶段 | 状态 | 功能 |
|------|------|------|
| **Phase 1** | ✅ 完成 | 框架 + 自检 + 配置模板 + setup 引导 |
| **Phase 2** | ✅ 完成 | 实现 deploy.sh / verify.sh / rollback.sh 主逻辑 |
| **Phase 3** | ✅ 完成 | 版本化部署 + 自动回滚 + 健康检查 |
| **Phase 4** | ✅ 完成 | prod 门禁 + 部署锁 + 分层配置 |
| **Phase 5** | ✅ 完成 | 四环境号段 + 环境差异化配置 + 端口变化检测 |
| **Phase 6** | ⏳ 待实现 | Docker 部署模式 |
| **Phase 7** | ⏳ 待实现 | Nginx 静态部署模式 |

## 已知限制

- ❌ Docker 部署模式未实现
- ❌ Nginx 静态部署模式未实现
- ❌ git ls-remote tag 验证待做(当前仅本地 git rev-parse)
- ❌ 增量部署支持待实现

## 维护人

- 主要:龙哥(邓云龙)
- AI 调度:呆呆
- 文档:本 README.md 和 setup.md

---

## 快速启动

1. 首次使用：阅读 `setup.md` 完成初始化
2. 检查环境：`bash scripts/doctor.sh`
3. 部署应用：`bash scripts/deploy.sh demo quanyu-console`
4. 部署原型：`bash scripts/deploy.sh proto smart-college-prototype`
5. 健康检查：`bash scripts/verify.sh demo quanyu-console`
6. 回滚：`bash scripts/rollback.sh demo quanyu-console`
---

## 路径校验机制（v1.1）

为避免"SSH 握手 + git pull 之后才发现项目路径不存在"的浪费式失败，deploy-app 加了三层防护：

### Layer 1：路径前置校验（强制，dry-run 也跑）
位置：`deploy.sh` Step 2.5/10（读完 `apps.json` 后立即执行）。

- 读到 `APP_PATH` 后立即 `[ -d "$APP_PATH" ]`。
- **dry-run 模式也强制检查**（不再"看上去通过、实跑才挂"）。
- 不存在则立即中止，并打印多行中文错误：期望路径、配置位置、可能原因、修复建议。

### Layer 2：framework 与路径一致性 warn
紧跟 Layer 1，对路径下关键文件做轻量探测，不中止部署：

| framework | 探测文件 | 缺失行为 |
|-----------|----------|----------|
| static    | `index.html`     | warn |
| nextjs    | `package.json`   | warn |
| nestjs    | `package.json`   | warn |
| express/node | `package.json` | warn |

### Layer 3：`doctor.sh --check-apps` 全量预扫描
位置：`scripts/doctor.sh --check-apps`

- 用 `jq` 遍历 `apps.json` 所有 app × `proto/test/demo/prod`。
- 对每个 (app, env)，优先 `env_config.<env>.project_path`；缺失时按 env 类型回退到 `project_proto_path` / `project_code_path`。
- 输出矩阵：`✅` 路径存在 / `❌` 路径不存在 / `—` 未配置。
- 末尾打印 "扫描完成，共 X 个应用，发现 Y 个路径错误"，发现错误时退出码为 1。

适合在每天/每次新增 app 后跑一次，提前发现路径配置漂移。

---

## 🆕 补充：未提及脚本与机制（2026-05-23）

### 1. `deploy-prototype.sh` —— 原型专门化部署

虽然 `deploy.sh proto <app>` 可以部署原型，但原型有自己的"专用快道"：

```bash
bash scripts/deploy-prototype.sh <app> [--skip-build] [--dry-run]
```

**与 `deploy.sh proto` 的差异：**

| 维度 | `deploy.sh proto` | `deploy-prototype.sh` |
|------|------------------|----------------------|
| 配置文件 | `environments.json` | `environments-prototype.json`（专用） |
| 流程 | 完整 10 步（含 git pull / 健康检查 / 失败回滚） | 精简快道（跳过 git 拉取 / 极简健康检查） |
| 适用 | 通用 proto 环境 | 高频迭代的原型仓库（如 smart-college-prototype） |
| 端口段 | 3000-3099 | 同段，但常用 30xx |
| 写日志 | 写 DEPLOY-LOG.md | 同样写 DEPLOY-LOG.md |

**何时用：**
- ✅ 原型源是 `docs-repos/<project>/prototype/` 这种"无构建"目录，每次小改频繁部署 → 用 `deploy-prototype.sh`
- ✅ 走标准 proto 环境配置 / 需要 git 拉取 / 有构建步骤 → 用 `deploy.sh proto <app>`

> 两条路最终都会用 `pm2 serve` 或等价静态服务托管，但 `deploy-prototype.sh` 的关键优势是"跳过仓库 git 操作"，特别适合 `docs-repos` 内 in-place 修改后立即上线。

### 2. `init-app.sh` —— 智能应用初始化向导

`init.sh` 是"通用交互式初始化"，而 `init-app.sh` 是"针对一个应用的智能向导版"。

```bash
# 已在 apps.json 的 app：交互确认补全
bash scripts/init-app.sh <app_key>

# 全新项目目录：自动探测 framework + 推荐配置
bash scripts/init-app.sh /abs/path/to/project

# 预览不写入
bash scripts/init-app.sh --dry-run <app_key>

# CI/批量场景，不弹交互
bash scripts/init-app.sh --no-interactive <app_key>
```

**智能推荐能力：**
- 探测 `package.json` 是否存在 → 推断 framework（next/nest/express/node/static）
- 探测 `next.config.{js,ts}` → 命中 `nextjs`
- 探测 `index.html` 且无 `package.json` → 命中 `static`
- 自动建议端口段（proto: 30xx / test: 32xx / demo: 34xx / prod: 36xx）

**输出：** 直接写入 `config/apps.json`（dry-run 模式仅打印 diff）。

**与 `init.sh` 的区别：**

| 脚本 | 目标 | 交互层级 |
|------|------|---------|
| `init.sh` | 初始化整套 deploy-app（apps.json + environments.json + 目录结构） | 重量级，一次性 |
| `init-app.sh` | 在已初始化的 deploy-app 里**新增/校准一个 app**条目 | 轻量级，可反复跑 |

### 3. Static framework 部署机制（serve.json + cleanUrls）

针对 static framework，今日（2026-05-23, TASK-009）补齐了三个坑：

#### 坑 1：`.html` URL 触发 301 重定向

`serve` 默认开 `cleanUrls`，访问 `/admin.html` 会 301 跳到 `/admin`，原型站常出现"链接全挂"。

#### 坑 2：SPA fallback 让所有 404 走 `index.html`

原 `serve -s` 模式（`--single`）会把所有未命中路径都返回 index.html，原型多页面场景全错。

#### 解决方案：自动写 `serve.json` + 去掉 `-s`

`deploy.sh` 在 static framework 部署时，自动在 `current/` 根目录生成：

```json
{
  "cleanUrls": false,
  "trailingSlash": false,
  "rewrites": []
}
```

启动命令也从：

```bash
pm2 start serve --name <app> -- -s . -l <port>
```

改为：

```bash
pm2 start serve --name <app> -- . -l <port>
```

> 去掉 `-s`，让 `.html` 真实命中文件、404 真实返回 404、`serve.json` 显式控制行为。

### 4. 多版本支持（与 prototype-design 联动）

当 `prototype-design` 的 `publish-version.sh` 把 `_archive/v3.0/` 发布到 `prototype/archive/v3.0/`，static 部署会自动一起带上：

```
<deploy_root>/<app>/current/
├── index.html              # 当前版本门户页（含版本切换器）
├── mapping.html
├── wireframe/...
├── highfi/...
└── archive/
    ├── v3.0/               # 历史版本可在线访问
    ├── v2.0/
    └── v1.0/
```

**关键点：**
- 不需要任何额外配置，`deploy.sh` 复制整个 `prototype/` 目录到 `current/` 即可
- 浏览器内的版本切换器（由 `generate-index.sh` 渲染）直接路径跳到 `archive/<v>/`
- `serve.json` 的 `cleanUrls:false` 让 `archive/v3.0/wireframe/admin.html` 也能直接命中

### 5. `doctor.sh --check-apps` 详解

补全 v1.1 Layer 3 的用法：

```bash
# 全量扫描所有 app × env 的路径配置
bash scripts/doctor.sh --check-apps

# 输出示例：
# 应用             | proto | test  | demo  | prod
# ----------------+-------+-------+-------+------
# smart-college   |  ✅   |  ✅   |  ✅   |  —
# quanyu-website  |  ✅   |  ❌   |  —    |  —
# ...
# 扫描完成：共 8 个应用，发现 1 个路径错误
# 退出码：1
```

**回退规则（优先级递减）：**
1. `apps.<app>.env_config.<env>.project_path`（精确配置）
2. proto 环境：`apps.<app>.project_proto_path`
3. test/demo/prod 环境：`apps.<app>.project_code_path`
4. 都没有 → `—`（不算错误）

**典型用途：**
- 🌅 每天上班第一件事跑一次，发现夜里被人改动的项目目录
- 🆕 新增 app 进 `apps.json` 后跑一次，确认路径都对
- 🚨 CI 定时任务，发现错误 → 钉钉/飞书报警

---

## 📋 v1.1+ 完整脚本能力矩阵（更新）

| 脚本 | 用途 | 何时用 |
|------|------|-------|
| `deploy.sh` | 主部署入口（10 步） | 95% 场景 |
| `deploy-prototype.sh` | 原型快道部署 | 高频迭代的原型仓库 |
| `rollback.sh` | 版本回滚 | 部署后发现问题 |
| `verify.sh` | 健康检查 | 部署后 / 定时巡检 |
| `doctor.sh` | 6 项自检 | 配置变更后 |
| `doctor.sh --check-apps` | app × env 路径矩阵扫描 | 每天 / 新增 app 后 |
| `init.sh` | 整套 deploy-app 初始化 | 第一次落地 |
| `init-app.sh` | 单 app 智能添加/校准 | 新增 app 或修配置 |

---

## 🔗 与其他 skill 的关系（更新）

- **`prototype-design`** → 生成的 `prototype/` 目录（含 `index.html` / `mapping.html` / `archive/`）直接被 `deploy.sh proto static` 整目录拷贝部署
- **`requirement`** → 不直接联动，但通过 prototype-design 间接消费需求
- **`dispatch-task`** → 派部署任务时必须带 env（proto/test/demo/prod）+ app + （prod 需 --version + --approved-by）
- **`skill: quanyu-tech-deployer`** → 角色 skill，负责调用本 skill 的脚本

