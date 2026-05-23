# project-mgmt setup

## 依赖
- `jq` — 必装（`sudo yum install -y jq` 或 `apt install -y jq`）
- `git` — 计算 commit 数时用
- `python3` — 时间戳格式化用

## 初始化
首次使用先建一次档案根目录（脚本会自动建，但你也可以手动）：
```bash
mkdir -p /var/lib/openclaw/.openclaw/workspace/knowledge-repos/projects
```

跑一遍 doctor，确认 `READY`：
```bash
bash /var/lib/openclaw/.openclaw/workspace/skills/project-mgmt/scripts/doctor.sh
```

## 常见问题
- **`_registry.json missing`** → doctor 会自动建空文件；如果还报错，看 `knowledge-repos/projects/` 权限
- **stage 不合法** → 合法集合：`planning / requirement / design / develop / test / live / deprecated`
- **新建时报 id 已存在** → 用 `update-status.sh` 改阶段，或在 incidents 里登记后退役
