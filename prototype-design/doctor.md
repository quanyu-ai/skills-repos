# prototype-design — 自检脚本说明

> `doctor.sh` 在每次使用本 skill 前必须运行，确认环境和配置就位。

---

## 检查项（9 项）

| # | 检查项 | 阻塞？ | 失败提示 |
|---|--------|--------|----------|
| 1 | `jq` 已安装 | ✅ | `jq not installed` |
| 2 | `config/projects.json` 存在 | ✅ | `projects.json missing` |
| 3 | `config/projects.json` JSON 有效 | ✅ | `projects.json invalid JSON` |
| 4 | `config/brand.json` 存在 | ✅ | `brand.json missing` |
| 5 | `config/brand.json` JSON 有效 | ✅ | `brand.json invalid JSON` |
| 6 | 模板目录 `templates/wireframe/` 存在 | ✅ | `wireframe templates missing` |
| 7 | 模板 `templates/wireframe/base.html` 存在 | ✅ | `wireframe base.html missing` |
| 8 | 目标项目目录 `docs-repos/<project>/` 存在 | ⚠️ | `WARN: project dir missing` |
| 9 | 需求条目可读 `requirements-map.json` | ⚠️ | `WARN: requirements-map.json missing` |

## 输出格式

- 最后一行 `READY` → 全部通过（可能有 WARN 行但不阻塞）
- 最后一行 `NEED_SETUP: <原因>` → 必须先修复再使用
- 退出码 0 = READY，1 = NEED_SETUP

## 使用

```bash
bash /var/lib/openclaw/.openclaw/workspace/skills/prototype-design/scripts/doctor.sh
```
