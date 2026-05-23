---
name: prototype-design
description: 原型设计 skill，根据需求条目自动生成多文件结构化原型（线框图 wireframe / 高仿真 highfi / 可交互 interactive 三种风格），支持按模块拆文件、自动维护需求映射、需求变更增量更新。
metadata: {"openclaw":{"emoji":"🎨","os":["linux"],"requires":{"bins":["jq"]}}}
user-invocable: true
---

# prototype-design — 原型设计 Skill 🎨

> 把"原型"做成可拆分、可索引、可增量更新的标准多文件工程。
> 一个项目 = 一个 `docs-repos/<project>/prototype/` 目录，按角色/模块拆分多个 HTML 文件。
> 主 Agent 不准再把所有页面塞进单文件巨型 HTML，所有原型必须通过本 skill 生成。
> 版本：Phase 1 框架（脚本骨架 + 模板，业务页面生成待 Phase 2 实现）

---

## 🚦 启动前自检（每次调用本 skill 第一步）

```bash
bash {{SKILL_DIR}}/scripts/doctor.sh
```

- 输出 `READY` → 进入正常流程
- 输出 `NEED_SETUP: <原因>` → **暂停操作**，先按 `setup.md` 引导完成初始化

`{{SKILL_DIR}}` 解析：本 skill 的根目录是
`/var/lib/openclaw/.openclaw/workspace/skills/prototype-design/`。

---

## ⛔ 红线（违反 = 任务失败）

1. ⛔ **禁止单文件巨型 HTML**：所有页面必须拆分到 `modules/<role>/<module>.html`
2. ⛔ **禁止把所有需求塞一个文件**：一个 HTML 文件最多对应 1-3 条相关 REQ
3. ⛔ **禁止跳过 requirements-map.json**：原型必须由需求条目驱动，不允许"凭感觉画"
4. ⛔ **禁止越权写入项目代码**：本 skill 只在 `docs-repos/<project>/prototype/**` 下写文件
5. ⛔ **禁止改动他人已 done 的原型**：变更必须新建模块文件或走 `revise-module.sh`
6. ⛔ **wireframe 风格禁用彩色/emoji/阴影**：违反规范要求请走 highfi 风格
7. ⛔ **禁止只更新正向 map**：每次 `generate.sh` 生成 HTML 后，必须反向回写 `REQ.related_files.prototype`，由脚本内置 assertion 强制。人工补救请走 `sync-back-refs.sh`

---

## 📋 使用场景

### 场景 1：首次生成项目原型骨架

```bash
bash {{SKILL_DIR}}/scripts/init.sh <project>
```

- 在 `docs-repos/<project>/prototype/` 下建标准目录（`_shared/` / `modules/` / `meta/`）
- 复制 `templates/shared/index.template.html` 作为项目主导航
- 复制 `templates/wireframe/styles.css` 到 `_shared/styles.css`
- 创建空 `meta/requirements-map.json` 和 `meta/revisions.md`
- **不生成任何业务页面**

### 场景 2：按需求批量生成原型页面

```bash
bash {{SKILL_DIR}}/scripts/generate.sh <style> <project> \
    [--modules <m1,m2>] [--role <role>] [--req <REQ-id>] [--phase 一阶段|二阶段]
```

| 参数 | 说明 |
|------|------|
| `<style>` | `wireframe` / `highfi` / `interactive` |
| `<project>` | 项目名（必须先用 `init.sh` 初始化） |
| `--modules` | 仅生成指定模块（逗号分隔） |
| `--role` | 仅生成指定角色的页面（如 `学院领导`） |
| `--req` | 仅生成指定 REQ-id 的页面 |
| `--phase` | 仅生成指定阶段的需求 |

读取 `docs-repos/<project>/requirements/requirements-map.json`，按角色/模块拆文件生成，同时：
- 更新 `meta/revisions.md`
- 更新 `prototype/meta/requirements-map.json`（正向映射）
- **自动反向回填** 到对应 REQ 文件的 `frontmatter.related_files.prototype`（脚本内置强制 + assertion，失败会 exit 1）

> ✅ **Phase 2 已实装**：
> - 批量生成（不再 head -1），assertion 验证 meta mapping 数量 == 过滤后 REQ 数量
> - 按 REQ 标题智能选业务模板：`workspace` / `dashboard` / `list` / `detail` / `form` / `base`
> - 业务模板位于 `templates/wireframe/business/`，基于 01-leader 黑白灰风格
> - 已有原型文件 + 已在 meta mapping 中的，默认不覆盖（保护存量页面）
> - 同一角色下多页会自动渲染完整 sidebar（含该角色所有页面链接）

### 场景 2.5：检测需求 ↔ 原型 差异

```bash
bash {{SKILL_DIR}}/scripts/diff-against-requirements.sh <project>
# 退出码：0=无差异，1=有差异（CI 可据此报警）
```

输出三块报告：
- ❶ 缺原型的 REQ（需新建）——含建议命令
- ❷ 应归档的原型（REQ 已 deprecated/删除）
- ❸ 可能过时的原型（REQ.updated > 原型.generated_at）

适用于 v3 → v4 大变更后一键看哪些原型该补/该砍/该改。

### 场景 3：增量加新模块

```bash
bash {{SKILL_DIR}}/scripts/add-module.sh <project> <module-name>
```

不动已有文件，仅新增 `modules/<role>/<module>.html` 并更新 `meta/requirements-map.json`。

### 场景 4：变更已有模块

```bash
bash {{SKILL_DIR}}/scripts/revise-module.sh <project> <module-name> <file>
```

按新需求重新生成单个模块文件（原文件归档到 `meta/archive/`），并在 `meta/revisions.md` 写一条记录。

### 场景 5：风格升级（wireframe → highfi → interactive）

```bash
bash {{SKILL_DIR}}/scripts/upgrade.sh <project> <from> <to>
```

> Phase 1：占位脚本，仅打印提示。Phase 3/4 实现。

### 场景 6：补救反向回填（历史遺留 / 人工表不一致）

```bash
# 干跑预览
bash {{SKILL_DIR}}/scripts/sync-back-refs.sh <project> --dry-run

# 真补救
bash {{SKILL_DIR}}/scripts/sync-back-refs.sh <project>
```

作用：以 `prototype/meta/requirements-map.json` 为准，把所有 mapping 的 files 路径都回写到对应 REQ 文件的 `related_files.prototype`。幂等（已存在跳过），完成后有 post-check assertion。

何时走：
- 旧项目正向 map 完备但 REQ 没同步
- doctor.sh 报 INCONSISTENT 时按提示手动修复
- 手动修过 REQ 后想重新同步

### 场景 7：生成需求-原型映射可视化页面

```bash
bash {{SKILL_DIR}}/scripts/generate-mapping.sh <project>
```

- 输出：`docs-repos/<project>/prototype/mapping.html`
- 内容：统计卡片（总需求 / 已映射 / 状态分布 / 阶段分布 / 优先级分布 / 角色分布）+ 按角色分组的 REQ-原型对照表（含状态色块、可点击原型链接、来源章节）
- 用途：客户 / 团队 review 时一眼看出需求完成度
- 数据源：`requirements/requirements-map.json` + `prototype/meta/requirements-map.json`，以 REQ-id 为 key 合并
- 通用脚本，任意项目（smart-college、chenxi-study 等）只要两份 json 按约定位置存在即可调用

---

## 📦 参数化设计

所有目标项目路径、风格、角色、模块，全部从命令行参数 + `config/projects.json` 解析，**脚本内不写死项目信息**。品牌色、公司名、默认风格统一走 `config/brand.json`。

---

## 🔄 与其他系统的关系

| 系统 | 关系 |
|------|------|
| `requirement` skill | 本 skill 的唯一输入源：读取 `docs-repos/<project>/requirements/requirements-map.json` |
| `deploy-app` skill | 生成的原型走 `deploy-app` 的 static 部署模式（Phase 6 实装） |
| `knowledge-repos/knowledge/general/prototype-design-spec.md` | 风格规范（黑白灰、无 emoji、极小圆角） |
| `knowledge-repos/management/TASK-TRACKER.json` | 原型生成任务必须先有 task 记录 |
| REQ 条目的 `related_files.prototype` | 生成时由本 skill 反写，关联 REQ ↔ HTML 文件 |

---

## 🔗 详细文档

- 首次安装引导：`setup.md`
- 自检脚本说明：`doctor.md`
- 完整设计：`README.md`
- 配置 schema：`config/schema.md`
- 品牌配置：`config/brand.json`
- 项目注册：`config/projects.json`

---

## 📌 Phase 路线

- **Phase 1（完成）**：框架 + 自检 + 模板 + 脚本骨架 + 1 个示例输出
- **Phase 2**：wireframe 风格完整业务页面生成（按角色/模块拆文件）
- **Phase 3（完成）**：REQ 反向回填闭环（generate.sh 内置 + sync-back-refs.sh 补救 + doctor.sh 双向一致性扫描，全部 assertion 硬执行）
- **Phase 4**：highfi 风格（品牌色 + 真实数据 + 完整视觉）
- **Phase 5**：interactive 风格（Tab/Modal/Chart 完整交互 + 弹窗联动）
- **Phase 6**：与 deploy-app skill 集成（一键 static 部署到 demo）
