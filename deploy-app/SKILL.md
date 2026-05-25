---
name: deploy-app
description: 标准化项目部署 skill，按照部署规范 v4.1 执行。支持 proto/test/demo/prod 四级环境。每次部署前会强制自检（apps.json/environments.json/SSH 密钥就绪状态），未就绪自动引导初始化。本机服务器也走 SSH 强制规范。
metadata: {"openclaw":{"emoji":"🚀","os":["linux"],"requires":{"bins":["ssh","scp","jq"]}}}
user-invocable: true
---

# deploy-app - 标准化部署 Skill 🚀

> 把"部署"做成一个可复用、可审计、可回滚的标准流程。
> 主 Agent 不准再手撕 `pm2 / scp / ssh / rsync`,所有部署动作必须通过本 skill 完成。
> 版本:Phase 1 框架(部署主逻辑待 Phase 2 实现)

---

## 🚦 启动前自检(每次调用本 skill 第一步)

**任何场景下,第一步必须运行 `doctor.sh`,根据输出决定下一步:**

```bash
bash {{SKILL_DIR}}/scripts/doctor.sh
```

- 输出 `READY` → 进入正常流程
- 输出 `NEED_SETUP: <原因>` → **暂停部署**,先按 `setup.md` 引导用户完成初始化
- 出现 `WARN:` 行 → 记录但不阻塞,提醒用户后续修复

`{{SKILL_DIR}}` 解析:本 skill 的根目录是
`/var/lib/openclaw/.openclaw/workspace/skills/deploy-app/`。

---

## 📋 四环境号段

| 环境 | 号段 | 用途 |
|------|------|------|
| **proto** | 3000-3099 | 原型部署，快速验证 |
| **test** | 3100-3199 | 功能/集成测试 |
| **demo** | 3200-3299 | 对外展示/客户演示 |
| **prod** | 3900-3999 | 生产环境 |

## 📋 使用场景

### 场景 1:首次安装(最关键)

- doctor 返回 `NEED_SETUP` 时触发
- 引导用户阅读 `setup.md`,完成:
  1. 安装依赖(jq / ssh)
  2. 复制并填写 `config/apps.json`(从 `INFRA-LEDGER.md` 自动提取)
  3. 复制并填写 `config/environments.json`
  4. 生成本机 `~/.ssh/deploy_local` 密钥并 `ssh-copy-id` 到 `deploy@localhost`
  5. 跑 `doctor.sh` 直到 `READY`

### 场景 2：正常部署

```bash
bash {{SKILL_DIR}}/scripts/deploy.sh <env> <app> [options]
```

**参数说明**：

| 参数 | 说明 |
|------|------|
| `<env>` | 环境名：`proto` / `test` / `demo` / `prod` |
| `<app>` | 应用 key（apps.json 中定义） |
| `--version` | 指定 git tag/sha（默认：当前分支 HEAD） |
| `--approved-by` | 审批人（prod 环境必需） |
| `--skip-build` | 跳过构建步骤 |
| `--dry-run` | 只打印操作，不实际执行 |

**示例**：

```bash
# 部署原型
bash {{SKILL_DIR}}/scripts/deploy.sh proto smart-college-prototype

# 部署测试
bash {{SKILL_DIR}}/scripts/deploy.sh test smart-college-prototype

# 部署演示
bash {{SKILL_DIR}}/scripts/deploy.sh demo smart-college-prototype

# 部署生产（需要审批）
bash {{SKILL_DIR}}/scripts/deploy.sh prod chenxi-backend --version v1.0.0 --approved-by longge

# 预览部署（不实际执行）
bash {{SKILL_DIR}}/scripts/deploy.sh demo quanyu-console --dry-run
```

部署完成后必须自动执行：
- `bash {{SKILL_DIR}}/scripts/verify.sh <env> <app>`（健康检查）
- 更新 `knowledge-repos/management/DEPLOY-LOG.md`（部署记录）
- 必要时更新 `INFRA-LEDGER.md`（端口/路径变化）

### 场景 3:排错(部署失败/服务异常)

1. 先 `doctor.sh` 确认 skill 自身就绪
2. 查看 `scripts/verify.sh` 的输出
3. 翻 `knowledge-repos/management/DEPLOY-LOG.md` 找最近一次成功部署
4. 必要时执行 `scripts/rollback.sh`

### 场景 4:回滚

```
bash {{SKILL_DIR}}/scripts/rollback.sh <env> <app> [target_version]
```

> Phase 1:占位脚本,仅打印提示。Phase 2 实现。

---

## ⛔ 红线(违反 = 任务失败)

1. ⛔ **禁止手撕** `pm2` / `scp` / `ssh` / `docker run` / `rsync` 等部署相关命令
2. ⛔ **禁止跳过 doctor.sh**(哪怕只是 demo 环境也要跑)
3. ⛔ **禁止把 `apps.json` / `environments.json` 提交进 git**(已在 `config/.gitignore` 拦截)
4. ⛔ **禁止以 `root` 身份直接部署**(必须用 `deploy` 用户 + 限定密钥)
5. ⛔ **本机也走 SSH**(`demo` 环境 host=localhost,但仍用 `~/.ssh/deploy_local` 走 ssh)
6. ⛔ **有公网 IP 的服务器必须用公网 IP 访问**(如 8.138.118.28 / 43.139.53.121)，禁止用 127.0.0.1 或 localhost

---

## 📦 参数化设计

部署命令统一形态:

```
deploy.sh <env> <app> [version]
verify.sh <env> <app>
rollback.sh <env> <app> [target_version]
```

所有目标地址、端口、启动命令、健康检查路径,全部从 `config/apps.json` + `config/environments.json` 解析,**脚本内不写死**。

---

## 🔄 环境差异化配置

apps.json 支持 `env_config` 字段，按环境覆盖配置：

```json
{
  "apps": {
    "smart-college-prototype": {
      "framework": "static",
      "env_config": {
        "proto": { "framework": "static" },
        "test": { "framework": "static" },
        "demo": { "framework": "static" },
        "prod": { "framework": "static" }
      }
    }
  }
}
```

**优先级**：`env_config.<env>` > 全局配置

**支持覆盖的字段**：display_name, framework, build_cmd, start_cmd, health_path 等

## 🔄 与其他系统的关系

| 系统 | 关系 |
|------|------|
| `knowledge-repos/management/DEPLOY-LOG.md` | 每次部署必写一条(时间 / env / app / version / 结果 / 操作人) |
| `knowledge-repos/management/INFRA-LEDGER.md` | 新增端口 / 域名 / 应用时同步更新 |
| `knowledge-repos/guides/deployment-standard.md` | 本 skill 是该规范的可执行实现 |
| `knowledge-repos/management/TASK-TRACKER.json` | 部署任务必须先有 task 记录 |

---

## 🔗 详细文档

- 首次安装引导:`setup.md`
- 自检脚本说明:`doctor.md`
- 配置文件 schema:`config/schema.md`
- 简介:`README.md`

---

## 📌 Phase 路线

- **Phase 1**：✅ 完成 - 框架 + 自检 + 配置模板 + setup 引导
- **Phase 2**：✅ 完成 - 实现 deploy.sh / verify.sh / rollback.sh 主逻辑
- **Phase 3**：✅ 完成 - 版本化部署 + 自动回滚 + 健康检查
- **Phase 4**：✅ 完成 - prod 门禁 + 部署锁 + 分层配置
- **Phase 5**：✅ 完成 - 四环境号段 + 环境差异化配置 + 端口变化检测
- **Phase 6**：⏳ 待实现 - Docker 部署模式
- **Phase 7**：⏳ 待实现 - Nginx 静态部署模式
