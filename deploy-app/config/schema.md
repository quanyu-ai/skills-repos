# Schema — apps.json & environments.json

deploy-app skill 的两份核心配置 schema 说明。**字段名严格按本表，不要私自改名。**

---

## apps.json

记录"应用本身"的元数据，与环境无关。

```jsonc
{
  "apps": {
    "<app_key>": {
      "display_name": "<string, required> 中文展示名",
      "repo_url":     "<string, required> git 仓库 URL（ssh 格式）",
      "project_path": "<string, required> 本机工作区内的绝对路径",
      "build_cmd":    "<string, required> 构建命令（一行 shell）",
      "start_cmd":    "<string, required> 启动命令（PM2 模式用）",
      "health_path":  "<string, required> 健康检查路径，如 /api/health",
      "framework":    "<enum, required> nextjs|nestjs|static|docker-only",
      "node_version": "<string, optional> 如 20.x",
      "env_files":    "<string[], optional> 需要额外加载的 .env 路径列表",
      "env_config":   "<object, optional, C+阶段> 按环境覆盖配置，详见下方「env_config 子 schema」"
    }
  }
}
```

### env_config 子 schema (C+ 阶段)

```jsonc
{
  "env_config": {
    "<env_name>": {                            // test/demo/prod
      "project_path": "<string, optional> 覆盖 app.project_path",
      "database": {                            // C 阶段
        "type":     "<enum> postgresql|mysql|redis",
        "host":     "<string>",
        "port":     "<int>",
        "database": "<string>",
        "username": "<string>",
        "password": "<string>"
      },
      "migration": {                           // D 阶段新增：插件化迁移声明
        "tool":        "<enum> prisma-postgresql|prisma-mysql|raw-sql|typeorm|flyway|liquibase|oracle-raw",
        "schema_path": "<string> 相对 project_path 的路径（文件或目录）",
        "commands": {                          // 可选：完全自定义命令（覆盖默认 npx prisma migrate deploy）
          "deploy": "<string> shell 命令",
          "seed":   "<string> shell 命令"
        },
        "options": {                           // 可选：工具特定参数
          "create_db_if_missing": "<bool>",
          "lock_timeout_ms":      "<int>"
        }
      }
    }
  }
}
```

`migration` 未声明 → migrate-db.sh 路由器会自动探测（prisma 路径 / SQL 目录）。详见 [MIGRATION-ARCHITECTURE.md](../../knowledge-repos/management/PRINCIPLES/MIGRATION-ARCHITECTURE.md)。

### `<app_key>` 命名规则

- 小写英文 + 短横线，如 `console`、`chenxi-web`、`sme-api`
- 必须在所有环境中唯一
- 不能与 PM2 已有进程名冲突

### `framework` 取值

| 值 | 说明 | 默认部署模式 |
|----|------|------|
| `nextjs` | Next.js 应用 | PM2 |
| `nestjs` | NestJS 后端 | PM2 |
| `static` | 纯静态文件（Vite/CRA build 产物） | 复制到 Nginx 目录 |
| `docker-only` | 仅支持 Docker 部署（如 prod） | Docker |

---

## environments.json

记录"环境 × 应用"的部署参数。

```jsonc
{
  "environments": {
    "<env_name>": {
      "host":             "<string, required> 目标主机 IP 或 localhost",
      "ssh_user":         "<string, required> SSH 登录用户，规范=deploy",
      "ssh_key":          "<string, required> 私钥路径，~ 会自动展开",
      "deploy_mode":      "<enum, required> pm2|docker",
      "deploy_base_path": "<string, required> 源码根目录（git pull 用），如 /var/lib/openclaw/.openclaw/workspace/code-repos",
      "deploy_root":      "<string, optional, Phase 3+> 版本化部署根目录，按 <root>/<app>/releases/<sha> 组织；未配置则回退到原地部署（旧行为）",
      "releases_to_keep": "<int, optional, Phase 3+> 保留的历史版本数（含当前），默认 3。部署成功后清理多余版本目录",
      "database_host":    "<string, optional, C 阶段+> 环境默认 DB 服务器 host，默认 localhost。用于 DB 服务器与 App 服务器分离场景；apps.json.env_config.<env>.database.host 可覆盖。参见 PRINCIPLES/DB-DEPLOY-INTEGRATION.md §十",
      "database_port":    "<int, optional, C 阶段+> 环境默认 DB 服务器 port，默认 5432",
      "nginx_conf_dir":   "<string, optional> Nginx 配置目录",
      "apps": {
        "<app_key>": {
          "port":     "<int, required> 监听端口（必须与 INFRA-LEDGER 一致）",
          "pm2_name": "<string, conditional> deploy_mode=pm2 时必填",
          "docker_image":  "<string, conditional> deploy_mode=docker 时必填",
          "docker_compose": "<string, optional> 自定义 compose 路径",
          "domain":   "<string, optional> 对外域名（用于 verify 健康检查）",
          "extra_env": "<object, optional> 部署时注入的额外环境变量"
        }
      }
    }
  }
}
```

### `<env_name>` 必须为以下之一

| 值 | 用途 | 推荐 deploy_mode |
|----|------|------|
| `demo` | 演示环境（给客户/老板看） | `pm2` |
| `test` | 集成测试环境 | `pm2` |
| `prod` | 生产环境 | `docker` |

### `port` 分配规则（与 INFRA-LEDGER 对齐）

- demo: `3100–3199`
- test: `3200–3299`
- prod: `3000–3099`（容器内端口，对外通过 Nginx 反代）

详见 `knowledge-repos/guides/deployment-standard.md §2.0`。

---

## 校验

- JSON 格式校验：`jq empty <file>`（doctor.sh 自动执行）
- Phase 2 将增加字段级 schema 校验（required / type / enum）

---

## Phase 3：版本化部署目录结构

当 `environments.<env>.deploy_root` 配置后，部署脚本会按下面结构组织产物，实现真正的版本回滚：

```
<deploy_root>/<app_key>/
  ├── current -> releases/<sha>           # 原子 symlink，PM2 的 cwd 指向这里
  └── releases/
      ├── <sha1>/                         # 按 git short sha 命名（无 git 时用时间戳）
      │   ├── .next/                      # build 产物
      │   ├── public/                     # 静态资源（如有）
      │   ├── package.json
      │   ├── node_modules -> <shared>    # symlink 到源码 node_modules，避免每版本重复占用磁盘
      │   └── ecosystem.config.cjs        # PM2 配置（cwd 指向自身目录）
      └── <sha2>/                         # 上一版本，rollback 用
<deploy_root>/shared/node_modules/
  └── <app_key> -> <project_path or monorepo_root>/node_modules
```

部署流程关键点：
1. 源码目录依旧用 `deploy_base_path`（git pull 在原位）；build 也在源码目录
2. build 完成后，把产物 **复制** 到 `releases/<sha>/`
3. node_modules 通过 symlink 共享，不复制
4. 原子切换 `current` symlink 后再 PM2 reload
5. 部署成功 → 保留最近 `releases_to_keep` 个版本，清理更旧的

回滚流程：
1. 找到 `releases/` 下排除 `current` 指向的最新一份
2. 原子切换 `current` symlink
3. PM2 reload（按 `current/ecosystem.config.cjs`）
4. 健康检查不过 → 退出非零，并保留 symlink 现状以便人工介入


---

## 安全提示

- ❌ 不要把真实 `apps.json` / `environments.json` 提交 git（已被 `.gitignore` 拦截）
- ✅ 模板文件 `*.template` 可以入库（仅含示例，无敏感信息）
- ✅ 基线文件 `environments.json.baseline` 必须入库（脱敏后的拓扑基准）
- ✅ 任何含密码 / token 的字段不要进 environments.json，改走 OpenClaw env 注入

---

## E 阶段：environments.json 三层配置结构（2026-05-26）

为了保证服务器拓扑基准能入 git、同时敏感凭据不泄露，environments.json 采用三层覆盖结构：

| 层级 | 文件 | git 状态 | 用途 |
|------|------|-----------|------|
| L1 baseline | `environments.json.baseline` | ✅ 入 git | 脱敏拓扑基准（IP/SSH 用户/部署路径/端口）|
| L2 machine | `environments.json` | ❌ gitignore | 本机覆盖（可含敏感字段）|
| L3 user | `environments.local.json` | ❌ gitignore | 用户最终覆盖（调试、湽道路由）|

**deploy.sh 读取顺序**：L2 是实际加载的定锐，L3 如存在则 deep merge 覆盖 L2。L1 仅作为拓扑基准 / 企业内可以共享参考。

**服务器层 vs 应用层**（E 阶段划清责任）：

| 字段类型 | 所在文件 |
|----------|----------|
| host / ssh_user / ssh_key / deploy_base_path / database_host / database_port | `environments.json` |
| port / pm2_name / build/start_cmd / migration / database 凭据 | `apps.json`（env_config.<env>.database）|

❗ `environments.json` 不再含 `database` 块（C 阶段后续清理，E 阶段完成彻底迁移）。

**host 强制公网 IP（AGENTS.md 铁律 6）**：deploy.sh 启动时 `validate_host_not_local` 拒绝 `localhost / 127.0.0.1 / ::1 / 0.0.0.0`，需要临时豁免用 `--allow-localhost`。详见 `knowledge-repos/management/PRINCIPLES/SERVER-CONFIG.md`。
