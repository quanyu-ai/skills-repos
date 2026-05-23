# solution-design — 首次使用引导

## 前置条件

- bash / coreutils（cp / mkdir / sed）— Linux 默认有
- 可选：`jq`（用于校验 `meta/version.json`，未来 Phase 2+ 必装）

## 第一次使用：3 步上手

### 步骤 1：跑自检

```bash
bash /var/lib/openclaw/.openclaw/workspace/skills/solution-design/scripts/doctor.sh
```

应输出 `READY`。否则按错误提示补齐。

### 步骤 2：为一个项目初始化方案目录

```bash
cd /var/lib/openclaw/.openclaw/workspace
bash skills/solution-design/scripts/init-solution.sh <project-name>
# 例：bash skills/solution-design/scripts/init-solution.sh smart-college
```

效果：
- 创建 `docs-repos/<project-name>/solution/` 完整骨架
- 写入 `solution/meta/version.json`（含项目名 + 初始化时间）
- 输出后续操作建议

### 步骤 3：填充方案内容

按以下顺序填写（推荐）：

1. `solution/architecture/overview.md` — 先把分层和模块清单写清楚
2. `solution/adr/ADR-001-tech-stack.md` — 记录技术选型决策（拷贝 `adr/_template.md`）
3. `solution/database/er-diagram.md` — ER 图（用 mermaid）
4. `solution/database/schema.md` — 表结构
5. `solution/api/api-design.md` — API 路由总览
6. `solution/modules/<module-name>/` — 每个业务模块一个目录（拷贝 `modules/_example/`）

## 常见问题

### Q: init-solution.sh 报"solution/ 已存在"

这是保护机制，**不会**自动覆盖。如确认要重建：

```bash
# 先手动备份/删除（必须龙哥确认）
mv docs-repos/<project>/solution docs-repos/<project>/solution.bak.$(date +%Y%m%d)
# 然后重新初始化
bash skills/solution-design/scripts/init-solution.sh <project>
```

### Q: 怎么新增一条 ADR？

```bash
PROJECT=smart-college
ADR_DIR=docs-repos/$PROJECT/solution/adr
NEXT=$(printf "%03d" $(($(ls $ADR_DIR/ADR-*.md 2>/dev/null | wc -l) + 1)))
cp skills/solution-design/templates/adr-template.md $ADR_DIR/ADR-${NEXT}-<short-title>.md
```

### Q: 模板想改怎么办？

直接改 `skills/solution-design/templates/` 下的文件，影响后续新建的项目。
已初始化的项目不会被回溯影响（git 留痕即可）。
