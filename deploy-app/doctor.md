# doctor.sh — 自检脚本说明

`scripts/doctor.sh` 是 deploy-app skill 的**门禁脚本**，任何部署动作前都必须先跑。

## 输出协议

- 退出码 `0` + 最后一行 `READY` → 一切就绪，可以执行部署
- 退出码 `1` + 最后一行 `NEED_SETUP: <reason>` → 必须先按 `setup.md` 修复
- 中间可出现若干 `WARN: <msg>` 行 → 不阻塞但需关注

## 检查项清单

| # | 检查 | 失败时返回 |
|---|------|------------|
| 1 | `config/apps.json` 存在 | `NEED_SETUP: apps.json missing` |
| 2 | `config/environments.json` 存在 | `NEED_SETUP: environments.json missing` |
| 3 | `apps.json` 是有效 JSON | `NEED_SETUP: apps.json invalid JSON` |
| 4 | `environments.json` 是有效 JSON | `NEED_SETUP: environments.json invalid JSON` |
| 5 | `~/.ssh/deploy_local` 私钥存在 | `NEED_SETUP: SSH deploy_local key missing` |
| 6 | `ssh <ssh_user>@localhost` 可联通 | `NEED_SETUP: SSH localhost not configured` |
| 7 | `ALIYUN_HOST` env 已注入 | `WARN: ALIYUN_HOST env not injected` |
| 8 | `TENCENT_HOST` env 已注入 | `WARN: TENCENT_HOST env not injected` |

## 依赖

- `jq`（必须装，否则脚本最早就会 `exit 1` 失败）
- `ssh` 客户端

## 在 OpenClaw 内调用

```bash
bash /var/lib/openclaw/.openclaw/workspace/skills/deploy-app/scripts/doctor.sh
```

或在 SKILL.md 的指导下让主 Agent 自动执行。

## Phase 2 计划

- 增加每个 env 的 SSH 联通检查（`prod` host 也要 ping 通）
- 增加 PM2 / Docker 二进制存在性检查（按 env.deploy_mode 决定）
- 增加 `apps.json` schema 校验（key 必填、port 数字等）
- 增加 git 工作区干净度检查
