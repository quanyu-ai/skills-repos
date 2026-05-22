# Setup — deploy-app Skill 首次安装引导

> 本文档由 `doctor.sh` 返回 `NEED_SETUP` 时触发阅读。
> 全程预计 15 分钟。涉及系统用户创建、SSH 配置等，建议在飞书端用 elevated 权限执行。

---

## 🚦 适用场景

- **首次安装 deploy-app skill**
- **环境变更需要重新初始化**
- **doctor.sh 返回 NEED_SETUP**

## Step 1：系统依赖安装

```bash
sudo yum install -y jq rsync
```

### 依赖说明

| 工具 | 用途 |
|------|------|
| `jq` | JSON 解析，配置文件读取 |
| `rsync` | 文件同步（PM2 模式部署时用） |
| `ssh` | 远程连接（本机也走 SSH） |

## Step 2：创建部署根目录

```bash
sudo mkdir -p /var/lib/openclaw/deploy-demo /var/lib/openclaw/deploy-test /var/lib/openclaw/deploy-prod
sudo chown -R openclaw:openclaw /var/lib/openclaw/deploy-*
sudo mkdir -p /var/lib/openclaw/deploy-locks
sudo chown openclaw:openclaw /var/lib/openclaw/deploy-locks
```

### 目录用途

| 目录 | 用途 |
|------|------|
| `deploy-demo/` | 演示环境部署产物 |
| `deploy-test/` | 测试环境部署产物 |
| `deploy-prod/` | 生产环境部署产物 |
| `deploy-locks/` | 部署锁文件 |

## Step 3：配置 SSH 密钥（本机 openclaw 用户）

### 重要背景

之前版本用 `deploy` 用户，但该用户没有 `/var/lib/openclaw/.openclaw/` 目录的访问权限（权限是 drwx------ openclaw:openclaw）。因此**必须使用 openclaw 用户**。

```bash
# 1. 生成 ED25519 密钥（无 passphrase）
ssh-keygen -t ed25519 -f ~/.ssh/deploy_local -N "" -C "deploy-app skill"

# 2. 加到 openclaw 用户的 authorized_keys（带 IP 白名单）
echo "from=\"127.0.0.1,::1\" $(cat ~/.ssh/deploy_local.pub)" >> ~/.ssh/authorized_keys

# 3. 确保 openclaw 用户 shell 是 bash（不是 nologin）
sudo usermod -s /bin/bash openclaw

# 4. 测试 SSH 连通性
ssh -i ~/.ssh/deploy_local -o StrictHostKeyChecking=no openclaw@localhost 'whoami && pm2 --version'
```

### 期望输出

```
openclaw
5.4.2
```

## Step 4：生成配置文件

```bash
cd /var/lib/openclaw/.openclaw/workspace/skills/deploy-app/config
cp apps.json.template apps.json
cp environments.json.template environments.json
```

### apps.json 配置

根据实际情况编辑 `config/apps.json`，每个应用必填字段：

```jsonc
"quanyu-console": {
  "display_name": "权舆系统展示控制台",
  "project_path": "/var/lib/openclaw/.openclaw/workspace/code-repos/quanyu-console",
  "repo_url": "git@github.com:quanyu-ai/quanyu-console.git",
  "build_cmd": "pnpm install --frozen-lockfile && pnpm build",
  "start_cmd": "pnpm start",
  "health_path": "/api/health",
  "framework": "nextjs"
}
```

### environments.json 配置

根据实际情况编辑 `config/environments.json`，每个环境必填字段：

```jsonc
"demo": {
  "host": "localhost",
  "ssh_user": "openclaw",
  "ssh_key": "~/.ssh/deploy_local",
  "deploy_mode": "pm2",
  "deploy_root": "/var/lib/openclaw/deploy-demo",
  "apps": {
    "quanyu-console": { "port": 3101, "pm2_name": "quanyu-console" }
  }
}
```

## Step 5：配置 OpenClaw env 注入

编辑 `~/.openclaw/openclaw.json`：

```json
{
  "skills": {
    "entries": {
      "deploy-app": {
        "enabled": true,
        "env": {
          "ALIYUN_HOST": "8.138.118.28",
          "TENCENT_HOST": "43.139.53.121",
          "DEPLOY_LOCAL_HOST": "localhost",
          "DEPLOY_LOG_PATH": "/var/lib/openclaw/.openclaw/workspace/knowledge-repos/management/DEPLOY-LOG.md"
        }
      }
    }
  }
}
```

### Env 变量说明

| 变量 | 用途 |
|------|------|
| `ALIYUN_HOST` | 阿里云服务器 IP |
| `TENCENT_HOST` | 腾讯云服务器 IP |
| `DEPLOY_LOCAL_HOST` | 本地主机名（通常是 localhost） |
| `DEPLOY_LOG_PATH` | DEPLOY-LOG.md 文件路径 |

**重启网关生效：**

```bash
# 彻底 kill 旧进程
sudo pkill -f "screen.*openclaw-gateway"
sudo pkill -f "node.*gateway --port 18789"
sleep 3

# 重新启动
sudo /var/lib/openclaw/start-gateway.sh
```

## Step 6：配置本地覆盖（可选）

如果本机的 SSH 用户名、密钥路径与默认值不同，创建 `config/environments.local.json`：

```json
{
  "environments": {
    "demo": {
      "ssh_user": "openclaw",
      "ssh_key": "~/.ssh/deploy_local"
    }
  }
}
```

### 特性

- 优先级高于 environments.json
- deep merge（嵌套字段会合并）
- 已被 gitignore，不会提交到代码库

## Step 7：运行 init.sh（可选）

交互式生成 apps.json 草稿：

```bash
bash scripts/init.sh
```

## Step 8：运行 doctor.sh 验证

```bash
bash scripts/doctor.sh
```

### 期望输出

```
READY
```

如果是 `NEED_SETUP`，回到对应步骤修复。

## Step 9：首次部署测试

```bash
# 1. 干跑（只打印命令）
bash scripts/deploy.sh demo test-demo --dry-run

# 2. 快速部署（跳过构建，用于已构建的项目）
bash scripts/deploy.sh demo test-demo --skip-build
```

## Step 10：验证部署

```bash
bash scripts/verify.sh demo test-demo
```

### 期望输出

```
▶ probing http://127.0.0.1:3200/
✓ attempt 1/10: HTTP 200 (alive)
HEALTHY
```

## 踩坑记录（6 个关键大坑）

### 坑 1：deploy 用户权限不足

**问题**：deploy 用户无法访问 /var/lib/openclaw/.openclaw/ 目录

**解决**：使用 openclaw 用户替代

### 坑 2：openclaw shell 默认 nologin

**问题**：SSH 连接成功但提示 "This account is currently not available"

**解决**：`sudo usermod -s /bin/bash openclaw`

### 坑 3：PM2 --name 参数不配合 ecosystem

**问题**：`pm2 start eco.cjs --name xxx` 会忽略 --name

**解决**：用 `--only <pm2_name>`

### 坑 4：PM2 reload 不更新 cwd

**问题**：cwd 是绝对路径时，reload 不会读取新的 symlink 目标

**解决**：检查 pm_cwd，不匹配则 delete+start

### 坑 5：PM2 不识别 .cjs 后缀

**问题**：ecosystem.config.cjs 不被识别

**解决**：文件名改成 ecosystem.config.cjs 并用 --only 参数

### 坑 6：部署锁未清理

**问题**：上次部署中断导致锁文件未删除

**解决**：`rm /var/lib/openclaw/deploy-locks/<app>.lock`

## 完成后

- ✅ 配置已完成
- ✅ SSH 连通
- ✅ 部署环境就绪
- ✅ 可以开始正常部署

---

## 常用命令速查

```bash
# 检查状态
bash scripts/doctor.sh

# 部署
bash scripts/deploy.sh demo quanyu-console

# 快速部署（跳过构建）
bash scripts/deploy.sh demo quanyu-console --skip-build

# 指定版本部署
bash scripts/deploy.sh demo quanyu-console --version v1.2.3

# 验证
bash scripts/verify.sh demo quanyu-console --strict

# 回滚
bash scripts/rollback.sh demo quanyu-console
```