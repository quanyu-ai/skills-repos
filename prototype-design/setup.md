# prototype-design — 首次使用引导

> 跟着这 9 步完成 skill 初始化，之后即可按场景使用。

---

## 前提

- OpenClaw 已安装并运行
- `jq` 已安装（`sudo apt-get install -y jq`）
- 至少有一个项目已通过 `requirement` skill 建立需求条目

## 步骤

### 1. 自检

```bash
bash /var/lib/openclaw/.openclaw/workspace/skills/prototype-design/scripts/doctor.sh
```

输出 `READY` → 继续步骤 3。输出 `NEED_SETUP` → 继续步骤 2。

### 2. 安装缺失依赖

按 doctor.sh 的提示安装。通常是 `jq`：

```bash
sudo apt-get install -y jq
```

重新运行 doctor.sh 直到 `READY`。

### 3. 注册项目

复制 `config/projects.json.template` 为 `config/projects.json`，填入项目信息：

```bash
cp skills/prototype-design/config/projects.json.template \
   skills/prototype-design/config/projects.json
```

编辑 `projects.json`，把你的项目加入 `"projects"` 对象。

### 4. 初始化项目原型骨架

```bash
bash skills/prototype-design/scripts/init.sh <project>
```

这会在 `docs-repos/<project>/prototype/` 下建标准目录结构。

### 5. 确认需求条目就位

确保 `docs-repos/<project>/requirements/requirements-map.json` 存在且有内容：

```bash
jq '.stats.total' docs-repos/<project>/requirements/requirements-map.json
```

输出应 > 0。若不存在，先运行 `requirement` skill 的 `sync-map.sh`。

### 6. 生成第一个原型

```bash
bash skills/prototype-design/scripts/generate.sh wireframe <project> --role <角色>
```

例如：`bash scripts/generate.sh wireframe smart-college --role 学院领导`

### 7. 检查生成结果

```bash
ls -la docs-repos/<project>/prototype/modules/
cat docs-repos/<project>/prototype/meta/revisions.md
```

### 8. 浏览原型

在浏览器打开 `docs-repos/<project>/prototype/index.html`，或通过 deploy-app 部署到 demo 服务器。

### 9. 后续使用

- 增量加模块：`bash scripts/add-module.sh <project> <module>`
- 改版：`bash scripts/revise-module.sh <project> <module> <file>`
- 风格升级：`bash scripts/upgrade.sh <project> wireframe highfi`

---

完成！🎉 本 skill 已就绪。
