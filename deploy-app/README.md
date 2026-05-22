# deploy-app 部署技能 README.md

## 1. 项目简介

deploy-app 是 OpenClaw 中的一个标准化部署技能，支持四种部署环境：原型环境（proto）、测试环境（test）、演示环境（demo）和生产环境（prod）。

## 2. 配置文件

### 2.1 apps.json

记录应用列表，每个项目对应一个 app_key，支持四种部署环境。

**文件位置：** `/var/lib/openclaw/.openclaw/workspace/skills/deploy-app/config/apps.json`

**结构示例：**

```json
{
  "$schema": "./schema.md",
  "_comment": "应用列表。每个项目对应一个 app_key，支持四种部署环境。",
  "apps": {
    "smart-college": {
      "display_name": "智能学院",
      "project_code_path": "/var/lib/openclaw/.openclaw/workspace/projects/smart-college",
      "project_proto_path": "/var/lib/openclaw/.openclaw/workspace/docs-repos/smart-college/prototype",
      "repo_url": "https://github.com/quanyu-ai/smart-college",
      "build_cmd": "npm run build",
      "start_cmd": "npm run start",
      "health_path": "/api/health",
      "framework": "nextjs",
      "env_config": {
        "proto": {
          "display_name": "智能学院原型",
          "project_path": "/var/lib/openclaw/.openclaw/workspace/docs-repos/smart-college/prototype",
          "build_cmd": "",
          "start_cmd": "node server.js",
          "health_path": "/",
          "framework": "static"
        },
        "test": {
          "display_name": "智能学院测试版",
          "project_path": "/var/lib/openclaw/.openclaw/workspace/projects/smart-college",
          "framework": "nextjs"
        },
        "demo": {
          "display_name": "智能学院演示版",
          "project_path": "/var/lib/openclaw/.openclaw/workspace/projects/smart-college",
          "framework": "nextjs"
        },
        "prod": {
          "display_name": "智能学院",
          "project_path": "/var/lib/openclaw/.openclaw/workspace/projects/smart-college",
          "framework": "nextjs"
        }
      }
    },
    "quanyu-console": {
      "display_name": "权舆控制台",
      "project_code_path": "/var/lib/openclaw/.openclaw/workspace/projects/quanyu-console",
      "project_proto_path": "/var/lib/openclaw/.openclaw/workspace/docs-repos/quanyu-console/prototype",
      "repo_url": "https://github.com/quanyu-ai/quanyu-console",
      "build_cmd": "npm run build",
      "start_cmd": "npm run start",
      "health_path": "/api/health",
      "framework": "nextjs",
      "env_config": {
        "proto": {
          "display_name": "权舆控制台原型",
          "project_path": "/var/lib/openclaw/.openclaw/workspace/docs-repos/quanyu-console/prototype",
          "build_cmd": "",
          "start_cmd": "node server.js",
          "health_path": "/",
          "framework": "static"
        },
        "test": {
          "display_name": "权舆控制台测试版",
          "project_path": "/var/lib/openclaw/.openclaw/workspace/projects/quanyu-console",
          "framework": "nextjs"
        },
        "demo": {
          "display_name": "权舆控制台演示版",
          "project_path": "/var/lib/openclaw/.openclaw/workspace/projects/quanyu-console",
          "framework": "nextjs"
        },
        "prod": {
          "display_name": "权舆控制台",
          "project_path": "/var/lib/openclaw/.openclaw/workspace/projects/quanyu-console",
          "framework": "nextjs"
        }
      }
    },
    "chenxi-backend": {
      "display_name": "晨曦学园",
      "project_code_path": "/var/lib/openclaw/.openclaw/workspace/code-repos/chenxi-backend",
      "repo_url": "https://github.com/chenxi-study/chenxi-backend",
      "build_cmd": "npm run build",
      "start_cmd": "npm run start",
      "health_path": "/health",
      "framework": "nestjs",
      "env_config": {
        "proto": {
          "display_name": "晨曦学园原型",
          "project_path": "/var/lib/openclaw/.openclaw/workspace/code-repos/chenxi-backend",
          "build_cmd": "",
          "start_cmd": "npm run dev",
          "health_path": "/health",
          "framework": "nestjs"
        },
        "test": {
          "display_name": "晨曦学园测试版",
          "project_path": "/var/lib/openclaw/.openclaw/workspace/code-repos/chenxi-backend",
          "framework": "nestjs"
        },
        "demo": {
          "display_name": "晨曦学园演示版",
          "project_path": "/var/lib/openclaw/.openclaw/workspace/code-repos/chenxi-backend",
          "framework": "nestjs"
        },
        "prod": {
          "display_name": "晨曦学园",
          "project_path": "/home/ubuntu/chenxi-study/chenxi-backend",
          "framework": "nestjs"
        }
      }
    }
  }
}
```

**字段说明：**

- **app_key**：项目唯一标识，英文拼写，如 "smart-college"
- **display_name**：项目中文名称
- **project_code_path**：项目代码路径，用作测试/演示/生产部署时使用
- **project_proto_path**：项目原型路径，仅用作原型部署时使用（可选）
- **repo_url**：项目 git 仓库地址
- **build_cmd**：构建命令（可选，静态项目可留空）
- **start_cmd**：启动命令（PM2 模式使用）
- **health_path**：健康检查路径（应当是有默认路径，但需考虑原型是否通用 /health 或 /）
- **framework**：框架类型（nextjs|nestjs|static|express）
- **env_config**：环境参数配置，包含四种部署环境的差异化配置

### 2.2 environments.json

记录环境参数配置，包含部署环境的连接方式、部署模式、应用的端口和实例名等。

**文件位置：** `/var/lib/openclaw/.openclaw/workspace/skills/deploy-app/config/environments.json`

**结构示例：**

```json
{
  "$schema": "./schema.md",
  "_comment": "环境配置表。每个环境定义连接方式 + 部署模式 + 各应用的端口和实例名。",
  "environments": {
    "proto": {
      "host": "localhost",
      "ssh_user": "openclaw",
      "ssh_key": "~/.ssh/deploy_local",
      "deploy_mode": "pm2",
      "deploy_base_path": "/var/lib/openclaw/.openclaw/workspace/docs-repos",
      "deploy_root": "/var/lib/openclaw/deploy-proto",
      "releases_to_keep": 3,
      "use_https_cookies": false,
      "node_env": "development",
      "apps": {
        "smart-college": { "port": 3001, "pm2_name": "proto-smart-college" },
        "quanyu-console": { "port": 3002, "pm2_name": "proto-quanyu-console" },
        "paiji": { "port": 3003, "pm2_name": "proto-paiji" },
        "chenxi-backend": { "port": 3004, "pm2_name": "proto-chenxi-backend" }
      }
    },
    "test": {
      "host": "localhost",
      "ssh_user": "openclaw",
      "ssh_key": "~/.ssh/deploy_local",
      "deploy_mode": "pm2",
      "deploy_base_path": "/var/lib/openclaw/.openclaw/workspace/projects",
      "deploy_root": "/var/lib/openclaw/deploy-test",
      "releases_to_keep": 3,
      "use_https_cookies": false,
      "node_env": "test",
      "apps": {
        "smart-college": { "port": 3101, "pm2_name": "test-smart-college" },
        "quanyu-console": { "port": 3102, "pm2_name": "test-quanyu-console" },
        "paiji": { "port": 3103, "pm2_name": "test-paiji" },
        "chenxi-backend": { "port": 3104, "pm2_name": "test-chenxi-backend" }
      }
    },
    "demo": {
      "host": "localhost",
      "ssh_user": "openclaw",
      "ssh_key": "~/.ssh/deploy_local",
      "deploy_mode": "pm2",
      "deploy_base_path": "/var/lib/openclaw/.openclaw/workspace/projects",
      "deploy_root": "/var/lib/openclaw/deploy-demo",
      "releases_to_keep": 3,
      "use_https_cookies": false,
      "node_env": "production",
      "apps": {
        "smart-college": { "port": 3201, "pm2_name": "demo-smart-college" },
        "quanyu-console": { "port": 3202, "pm2_name": "demo-quanyu-console" },
        "paiji": { "port": 3203, "pm2_name": "demo-paiji" },
        "chenxi-backend": { "port": 3204, "pm2_name": "demo-chenxi-backend" }
      }
    },
    "prod": {
      "host": "43.139.53.121",
      "ssh_user": "ubuntu",
      "ssh_key": "~/.ssh/deploy_prod",
      "deploy_mode": "pm2",
      "deploy_base_path": "/home/ubuntu/chenxi-study/chenxi-backend",
      "deploy_root": "/var/lib/openclaw/deploy-prod",
      "releases_to_keep": 5,
      "use_https_cookies": true,
      "node_env": "production",
      "apps": {
        "chenxi-backend": { "port": 3901, "pm2_name": "chenxi-backend" }
      }
    }
  }
}
```

**字段说明：**

- **env_name**：环境名称，包含四种部署环境：proto（原型环境）、test（测试环境）、demo（演示环境）和 prod（生产环境）
- **host**：目标主机的IP地址
- **ssh_user**：SSH登录用户
- **ssh_key**：SSH私钥路径
- **deploy_mode**：部署模式，支持 pm2 和 docker
- **deploy_base_path**：项目部署的基础路径
- **deploy_root**：项目部署的根路径
- **releases_to_keep**：保留的历史版本数量
- **use_https_cookies**：是否使用HTTPS cookie
- **node_env**：Node.js环境变量
- **apps**：包含各个应用的端口和实例名

## 3. 使用说明

### 3.1 部署命令

部署命令格式：

```bash
/deploy-app <环境名> <应用名> [--version <版本>] [--approved-by <审批人>] [--dry-run]
```

**参数说明：**

- `<环境名>`：部署环境，可以是 proto、test、demo 或 prod
- `<应用名>`：应用名称，对应 apps.json 中的 app_key
- `--version`：指定部署版本（可选）
- `--approved-by`：指定审批人（可选，生产环境必需）
- `--dry-run`：只打印命令，不实际执行（可选）

**示例：**

```bash
# 部署智能学院原型到原型环境
/deploy-app proto smart-college

# 部署智能学院测试版到测试环境，指定版本为 v1.0.0
/deploy-app test smart-college --version v1.0.0

# 部署智能学院演示版到演示环境，只打印命令
/deploy-app demo smart-college --dry-run

# 部署晨曦学园到生产环境，指定版本和审批人
/deploy-app prod chenxi-backend --version v1.0.0 --approved-by "longge"
```

## 4. 部署流程

deploy.sh 是主部署脚本，包含以下流程：

1. 验证输入参数
2. 读取配置文件
3. 根据环境自动选择项目路径
4. 执行部署操作
5. 健康检查
6. 完成部署

## 5. 辅助脚本

### 5.1 deploy-prototype.sh

专门为原型部署优化的脚本，支持快速原型验证。

**使用方法：**

```bash
/deploy-prototype.sh <应用名> [--version <版本>] [--dry-run]
```

### 5.2 rollback.sh

用于回滚到上一个版本的脚本。

**使用方法：**

```bash
/rollback.sh <环境名> <应用名> [--version <版本>]
```

### 5.3 verify.sh

用于健康检查的脚本。

**使用方法：**

```bash
/verify.sh <环境名> <应用名> [--timeout <超时时间>]
```

## 6. 项目类型分类

### 6.1 前端项目（Next.js）

```json
"quanyu-console": {
  "display_name": "权舆控制台",
  "project_code_path": "/var/lib/openclaw/.openclaw/workspace/projects/quanyu-console",
  "project_proto_path": "/var/lib/openclaw/.openclaw/workspace/docs-repos/quanyu-console/prototype",
  "repo_url": "https://github.com/quanyu-ai/quanyu-console",
  "build_cmd": "npm run build",
  "start_cmd": "npm run start",
  "health_path": "/api/health",
  "framework": "nextjs",
  "env_config": {
    "proto": {
      "display_name": "权舆控制台原型",
      "project_path": "/var/lib/openclaw/.openclaw/workspace/docs-repos/quanyu-console/prototype",
      "build_cmd": "",
      "start_cmd": "node server.js",
      "health_path": "/",
      "framework": "static"
    },
    "test": {
      "display_name": "权舆控制台测试版",
      "project_path": "/var/lib/openclaw/.openclaw/workspace/projects/quanyu-console",
      "framework": "nextjs"
    },
    "demo": {
      "display_name": "权舆控制台演示版",
      "project_path": "/var/lib/openclaw/.openclaw/workspace/projects/quanyu-console",
      "framework": "nextjs"
    },
    "prod": {
      "display_name": "权舆控制台",
      "project_path": "/var/lib/openclaw/.openclaw/workspace/projects/quanyu-console",
      "framework": "nextjs"
    }
  }
}
```

### 6.2 后端项目（NestJS）

```json
"chenxi-backend": {
  "display_name": "晨曦学园",
  "project_code_path": "/var/lib/openclaw/.openclaw/workspace/code-repos/chenxi-backend",
  "repo_url": "https://github.com/chenxi-study/chenxi-backend",
  "build_cmd": "npm run build",
  "start_cmd": "npm run start",
  "health_path": "/health",
  "framework": "nestjs",
  "env_config": {
    "proto": {
      "display_name": "晨曦学园原型",
      "project_path": "/var/lib/openclaw/.openclaw/workspace/code-repos/chenxi-backend",
      "build_cmd": "",
      "start_cmd": "npm run dev",
      "health_path": "/health",
      "framework": "nestjs"
    },
    "test": {
      "display_name": "晨曦学园测试版",
      "project_path": "/var/lib/openclaw/.openclaw/workspace/code-repos/chenxi-backend",
      "framework": "nestjs"
    },
    "demo": {
      "display_name": "晨曦学园演示版",
      "project_path": "/var/lib/openclaw/.openclaw/workspace/code-repos/chenxi-backend",
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
