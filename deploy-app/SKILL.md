---
name: deploy-app
description: 标准化项目部署 skill，按照部署规范 v4.1 执行。支持 demo/test/prod 三级环境。每次部署前会强制自检（apps.json/environments.json/SSH 密钥就绪状态），未就绪自动引导初始化。本机服务器也走 SSH 强制规范。
metadata: {"openclaw":{"emoji":"🚀","os":["linux"],"requires":{"bins":["ssh","scp","jq"]}}}
user-invocable: true
---

# deploy-app — 标准化部署 Skill 🚀

> 把"部署"做成一个可复用、可审计、可回滚的标准流程。
> 主 Agent 不准再手撕 `pm2 / scp / ssh / rsync`，所有部署动作必须通过本 skill 完成。
> 版本：Phase 1 框架（部署主逻辑待 Phase 2 实现）

---

## 🚦 启动前自检（每次调用本 skill 第一步）

**任何场景下，第一步必须运行 `doctor.sh`，根据输出决定下一步：**

```bash
bash {{SKILL_DIR}}/scripts/doctor.sh
```

- 输出 `READY` → 进入正常流程
- 输出 `NEED_SETUP: <原因>` → **暂停部署**，先按 `setup.md` 引导用户完成初始化
- 出现 `WARN:` 行 → 记录但不阻塞，提醒用户后续修复

`{{SKILL_DIR}}` 解析：本 skill 的根目录是
`/var/lib/openclaw/.openclaw/workspace/skills/deploy-app/`。

---

## 📋 使用场景

### 场景 1：首次安装（最关键）

- doctor 返回 `NEED_SETUP` 时触发
- 引导用户阅读 `setup.md`，完成：
  1. 安装依赖（jq / ssh）
  2. 复制并填写 `config/apps.json`（从 `INFRA-LEDGER.md` 自动提取）
  3. 复制并填写 `config/environments.json`
  4. 生成本机 `~/.ssh/deploy_local` 密钥并 `ssh-copy-id` 到 `deploy@localhost`
  5. 跑 `doctor.sh` 直到 `READY`

### 场景 2：正常部署

```
bash {{SKILL_DIR}}/scripts/deploy.sh <env> <app> [version]
```

- `<env>`：`demo` / `test` / `prod`
- `<app>`：`apps.json` 里定义的应用 key（如 `console`）
- `[version]`：可选 git tag/commit，缺省 = 当前默认分支

部署完成后必须自动执行：
- `bash {{SKILL_DIR}}/scripts/verify.sh <env> <app>`（健康检查）
- 更新 `knowledge-repos/management/DEPLOY-LOG.md`（部署记录）
- 必要时更新 `INFRA-LEDGER.md`（端口/路径变化）

> ⚠️ Phase 1：`deploy.sh / verify.sh` 仅为占位，会输出"待 Phase 2 实现"并退出 2。
> 在 Phase 2 完成前，部署仍按 `knowledge-repos/guides/deployment-standard.md` **手动执行**，但仍要在执行前后跑 `doctor.sh` 验证环境。

### 场景 3：排错（部署失败/服务异常）

1. 先 `doctor.sh` 确认 skill 自身就绪
2. 查看 `scripts/verify.sh` 的输出
3. 翻 `knowledge-repos/management/DEPLOY-LOG.md` 找最近一次成功部署
4. 必要时执行 `scripts/rollback.sh`

### 场景 4：回滚

```
bash {{SKILL_DIR}}/scripts/rollback.sh <env> <app> [target_version]
```

> Phase 1：占位脚本，仅打印提示。Phase 2 实现。

---

## ⛔ 红线（违反 = 任务失败）

1. ⛔ **禁止手撕** `pm2` / `scp` / `ssh` / `docker run` / `rsync` 等部署相关命令
2. ⛔ **禁止跳过 doctor.sh**（哪怕只是 demo 环境也要跑）
3. ⛔ **禁止把 `apps.json` / `environments.json` 提交进 git**（已在 `config/.gitignore` 拦截）
4. ⛔ **禁止以 `root` 身份直接部署**（必须用 `deploy` 用户 + 限定密钥）
5. ⛔ **本机也走 SSH**（`demo` 环境 host=localhost，但仍用 `~/.ssh/deploy_local` 走 ssh）

---

## 📦 参数化设计

部署命令统一形态：

```
deploy.sh <env> <app> [version]
verify.sh <env> <app>
rollback.sh <env> <app> [target_version]
```

所有目标地址、端口、启动命令、健康检查路径，全部从 `config/apps.json` + `config/environments.json` 解析，**脚本内不写死**。

---

## 🔄 与其他系统的关系

| 系统 | 关系 |
|------|------|
| `knowledge-repos/management/DEPLOY-LOG.md` | 每次部署必写一条（时间 / env / app / version / 结果 / 操作人） |
| `knowledge-repos/management/INFRA-LEDGER.md` | 新增端口 / 域名 / 应用时同步更新 |
| `knowledge-repos/guides/deployment-standard.md` | 本 skill 是该规范的可执行实现 |
| `knowledge-repos/management/TASK-TRACKER.json` | 部署任务必须先有 task 记录 |

---

## 🔗 详细文档

- 首次安装引导：`setup.md`
- 自检脚本说明：`doctor.md`
- 配置文件 schema：`config/schema.md`
- 简介：`README.md`

---

## 📌 Phase 路线

- **Phase 1（当前）**：框架 + 自检 + 配置模板 + setup 引导
- **Phase 2**：实现 `deploy.sh / verify.sh / rollback.sh` 主逻辑（PM2 / Docker 两种模式）
- **Phase 3**：注入 OpenClaw env（在 `~/.openclaw/openclaw.json` 的 `skills.entries.deploy-app.env` 配置主机白名单）
- **Phase 4**：接入 CI/CD 与告警
