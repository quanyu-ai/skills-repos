# prototype-design — 原型设计 Skill 🎨

> 把"原型"做成可拆分、可索引、可增量更新的标准多文件工程。所有项目原型必须通过本 skill 生成，绝不允许"一锅炖"巨型 HTML。

---

## 项目简介

prototype-design 是 OpenClaw 的标准化原型设计 Skill，把"画原型"这件事变成由需求驱动、多文件结构化、可增量更新的工程流程。

它把 `requirement` skill 产出的 `requirements-map.json` 作为唯一输入，按角色 → 模块 → 文件三级拆分，自动生成 wireframe / highfi / interactive 三种风格的 HTML 原型，并把生成结果反写回 REQ 条目的 `related_files.prototype`，形成"需求 ↔ 原型"双向追踪。

## 设计理念

### 核心问题

之前的原型工作流有 5 个老大难：

1. **单文件巨型 HTML**：一个 `index.html` 塞 30+ 页面 + 200KB 内联 JS，AI 改不动、人也读不动
2. **不可索引**：找"那个学生工作台原型"靠 Ctrl+F + 肉眼
3. **不可增量**：加一个模块要全文件重写，每次都触发全量 git diff
4. **风格不统一**：今天用蓝色按钮、明天用绿色按钮，没有规范约束
5. **需求-原型断链**：改了需求文档不知道哪个原型受影响

### 解决方案

- **多文件拆分**：`modules/<role>/<module>.html` 一文件一职责
- **需求驱动**：`requirements-map.json` 是唯一输入源，不允许"凭感觉画"
- **三层风格**：wireframe（结构）/ highfi（视觉）/ interactive（交互）渐进式升级
- **共享组件**：`_shared/components/` 集中维护 navbar / sidebar / chart-placeholder 等
- **元信息台账**：`meta/requirements-map.json` 反查"哪个 REQ 对应哪个 HTML"
- **变更归档**：`revise-module.sh` 把旧版本归档到 `meta/archive/<timestamp>/`
- **配置化品牌**：`config/brand.json` 统一品牌色、公司名、默认风格

## 能力清单

### 核心功能

- ✅ **项目初始化**：`init.sh` 一键搭建标准目录骨架
- ✅ **参数化生成**：`generate.sh` 支持按风格/角色/模块/REQ-id/阶段过滤
- ✅ **增量加模块**：`add-module.sh` 不动已有文件，只追加新模块
- ✅ **模块改版**：`revise-module.sh` 重生成单模块，旧版归档
- ✅ **风格升级**：`upgrade.sh` wireframe → highfi → interactive
- ✅ **自检**：`doctor.sh` 9 项检查（jq / 模板 / 配置 / 目录就位）
- ✅ **变更日志**：自动维护 `meta/revisions.md`
- ✅ **需求映射反写**：生成时把 HTML 路径写入 REQ 条目的 `related_files.prototype`

### 支持的风格

| 风格 | 颜色 | emoji | 圆角 | 数据 | 交互 | 用途 |
|------|------|-------|------|------|------|------|
| `wireframe` | 黑白灰 | ❌ | 2px | 占位 | 切换页面 | 评审结构 |
| `highfi` | 品牌色 | ✅ | 8px | 真实示例 | 切换页面 + Tab | 评审视觉 |
| `interactive` | 品牌色 | ✅ | 8px | 真实示例 | + Modal + Chart | 演示给客户 |

### 支持的拆文件策略

- ✅ **按角色拆**：`modules/学院领导/dashboard.html`、`modules/教师/dashboard.html`
- ✅ **按模块拆**：`modules/<role>/<module>.html`，一个模块对应 1-3 条 REQ
- ✅ **共享组件**：`_shared/components/*.html` 通过 fetch 注入
- ✅ **共享样式**：`_shared/styles.css` 一个项目一份

## 架构图

```
┌──────────────────────────────────────────────────────────┐
│              prototype-design Skill                       │
├──────────────────────────────────────────────────────────┤
│  📥 输入层                                                 │
│  - docs-repos/<project>/requirements/requirements-map.json│
│  - config/projects.json                                    │
│  - config/brand.json                                       │
├──────────────────────────────────────────────────────────┤
│  🛠️  执行层                                                │
│  - scripts/init.sh           初始化项目骨架                 │
│  - scripts/generate.sh       主生成（按风格/角色/模块）      │
│  - scripts/add-module.sh     增量加模块                    │
│  - scripts/revise-module.sh  改版（归档 + 重生成）          │
│  - scripts/upgrade.sh        风格升级                       │
│  - scripts/doctor.sh         9 项自检                       │
├──────────────────────────────────────────────────────────┤
│  📤 输出层                                                 │
│  docs-repos/<project>/prototype/                          │
│  ├── index.html              主导航                        │
│  ├── _shared/                共享样式 + 组件                │
│  ├── modules/<role>/<m>.html 按模块拆分的页面               │
│  └── meta/                   元信息 + 变更日志              │
├──────────────────────────────────────────────────────────┤
│  🔁 反写                                                   │
│  - 把生成的 HTML 路径写回 REQ 条目的 related_files.prototype │
└──────────────────────────────────────────────────────────┘
```

## 目录结构

### Skill 自身

```
/var/lib/openclaw/.openclaw/workspace/skills/prototype-design/
├── SKILL.md                          # 触发入口 + 红线规则
├── README.md                         # 本文档
├── setup.md                          # 首次使用引导
├── doctor.md                         # 自检脚本说明
├── config/
│   ├── projects.json.template        # 已注册项目模板
│   ├── brand.json                    # 品牌配置（权舆默认）
│   └── schema.md                     # 字段说明
├── scripts/
│   ├── doctor.sh                     # 9 项自检
│   ├── init.sh                       # 初始化项目骨架
│   ├── generate.sh                   # 主生成脚本
│   ├── add-module.sh                 # 增量加模块
│   ├── revise-module.sh              # 改版（归档 + 重生成）
│   └── upgrade.sh                    # 风格升级
└── templates/
    ├── wireframe/
    │   ├── base.html                 # 线框图基础模板
    │   ├── styles.css                # 线框图通用样式
    │   └── components.html           # 通用组件库
    ├── highfi/
    │   └── base.html                 # 高仿真基础模板（Phase 3）
    └── shared/
        └── index.template.html       # 项目主导航模板
```

### 生成产物（每个项目）

```
docs-repos/<project>/prototype/
├── index.html                        # 项目主导航（6 角色入口卡片）
├── _shared/
│   ├── styles.css                    # 该项目专用样式（继承 wireframe/styles.css）
│   ├── nav.html                      # 通用顶部导航
│   ├── sidebar.html                  # 通用侧边栏
│   └── components/                   # 复用组件
├── modules/
│   ├── 学院领导/
│   │   ├── dashboard.html            # 对应 REQ-001 学院领导-工作台
│   │   ├── cockpit.html              # 对应 REQ-002 领导驾驶舱
│   │   └── ...
│   ├── 教师/
│   ├── 辅导员/
│   ├── 学生/
│   ├── 校友/
│   └── 管理员/
└── meta/
    ├── requirements-map.json         # 本项目"REQ ↔ HTML"映射
    ├── revisions.md                  # 变更日志（人读）
    └── archive/                      # 历史版本归档
        └── 2026-05-22T18-00/
            └── modules/教师/dashboard.html
```

## 参数化使用

### init.sh（初始化骨架）

```bash
bash scripts/init.sh <project>
```

| 参数 | 说明 |
|------|------|
| `<project>` | 项目目录名（`docs-repos/<project>/` 必须存在） |

### generate.sh（主生成）

```bash
bash scripts/generate.sh <style> <project> [选项...]
```

| 参数 | 说明 |
|------|------|
| `<style>` | `wireframe` / `highfi` / `interactive` |
| `<project>` | 项目名（必须已 `init.sh`） |
| `--modules <m1,m2>` | 仅生成指定模块，逗号分隔 |
| `--role <role>` | 仅生成指定角色（如 `学院领导`） |
| `--req <REQ-id>` | 仅生成指定 REQ（如 `REQ-20260522-001`） |
| `--phase <phase>` | 仅生成指定阶段（`一阶段` / `二阶段`） |
| `--dry-run` | 只打印将生成的文件清单，不实际写入 |

### add-module.sh（增量加模块）

```bash
bash scripts/add-module.sh <project> <module-name>
```

### revise-module.sh（改版）

```bash
bash scripts/revise-module.sh <project> <module-name> <file>
```

把旧 `<file>` 归档到 `meta/archive/<timestamp>/`，按 REQ 重生成。

### upgrade.sh（风格升级）

```bash
bash scripts/upgrade.sh <project> <from> <to>
```

例：`bash scripts/upgrade.sh smart-college wireframe highfi`

### doctor.sh（自检）

```bash
bash scripts/doctor.sh
```

输出 `READY` 表示可用，`NEED_SETUP` 表示需先按 `setup.md` 初始化。

## 三种风格对比

### wireframe（线框图）

- **目的**：让评审者只看结构、内容、操作流程，不被颜色干扰
- **配色**：纯黑白灰（`#000` / `#666` / `#ccc` / `#f5f5f5` / `#fff`）
- **排版**：极小圆角（2px）、无阴影、细边框（1px solid #ccc）
- **图标**：禁用 emoji，用文字符号（`▶` / `■` / `→`）
- **数据**：占位文字 + 灰色块表示图表区域

### highfi（高仿真）

- **目的**：在已通过 wireframe 评审的基础上，加上视觉规范
- **配色**：品牌色（`config/brand.json` 中的 `brand_color`，权舆默认 `#E8622C`）
- **排版**：8px 圆角、轻阴影、品牌色 hover
- **图标**：允许 emoji 或简洁矢量图标
- **数据**：真实业务示例数据（学生姓名、班级、成绩等）

### interactive（可交互）

- **目的**：演示给客户看的交付级原型
- **额外能力**：完整 Modal 弹窗、Tab 切换、Chart.js 图表、表单校验、分页交互
- **数据**：真实业务示例数据 + 模拟交互回执

## 拆文件策略

### 按角色拆（默认）

每个角色一个子目录：`modules/<角色>/`。这是最自然的拆法——不同角色看到的东西完全不同。

```
modules/
├── 学院领导/     # REQ-001 ~ REQ-010
├── 教师/         # REQ-011 ~ REQ-018
├── 辅导员/       # REQ-019 ~ REQ-028
├── 学生/         # REQ-029 ~ REQ-039
├── 校友/         # REQ-040
└── 管理员/       # REQ-041 ~ REQ-045
```

### 按模块拆（进阶）

角色下按功能模块进一步拆：一个 HTML 对应 1-3 条 REQ。

```
modules/学院领导/
├── dashboard.html     # REQ-001 学院领导-工作台
├── cockpit.html       # REQ-002 领导驾驶舱
├── schedule.html      # REQ-003 每周工作日程
├── supervision.html   # REQ-004 重大事项督办
└── assessment.html    # REQ-005 教职工考核
```

### 共享组件

`_shared/components/` 存放所有角色共用的 UI 组件。页面通过 `<iframe>` 或 `fetch()` + `innerHTML` 注入共享 header/sidebar/footer。

| 组件 | 文件 | 说明 |
|------|------|------|
| navbar | `_shared/components/navbar.html` | 顶部导航栏 |
| sidebar | `_shared/components/sidebar.html` | 左侧菜单栏 |
| breadcrumb | `_shared/components/breadcrumb.html` | 面包屑导航 |
| data-table | `_shared/components/data-table.html` | 通用数据表格 |
| form | `_shared/components/form.html` | 通用表单 |
| modal | `_shared/components/modal.html` | 弹窗/对话框 |
| chart-placeholder | `_shared/components/chart-placeholder.html` | 图表占位（wireframe） |
| kpi-card | `_shared/components/kpi-card.html` | KPI 指标卡片 |

## 需求映射机制

### 输入：requirements-map.json

由 `requirement` skill 的 `sync-map.sh` 维护，格式如下：

```json
{
  "requirements": {
    "REQ-20260522-001": {
      "id": "REQ-20260522-001",
      "title": "学院领导-工作台",
      "role": "学院领导",
      "status": "approved",
      "priority": "P0"
    }
  }
}
```

### 输出：prototype 的 meta/requirements-map.json

本 skill 在生成时维护一个本地映射，记录"REQ ↔ HTML 文件"关系：

```json
{
  "project": "smart-college",
  "style": "wireframe",
  "updated": "2026-05-22T18:00:00+08:00",
  "mappings": [
    {
      "req_id": "REQ-20260522-001",
      "title": "学院领导-工作台",
      "role": "学院领导",
      "files": ["modules/学院领导/dashboard.html"],
      "generated_at": "2026-05-22T18:00:00+08:00"
    }
  ]
}
```

### 反写：REQ 条目的 related_files.prototype

生成完成后，脚本读取 `meta/requirements-map.json`，对每条 REQ：

1. 读取 `docs-repos/<project>/requirements/REQ-*.md`
2. 在 frontmatter 的 `related_files.prototype` 字段追加 HTML 路径
3. 更新 `updated` 日期

这样从需求侧也能查到"这个 REQ 对应哪个原型文件"。

## 变更/新增需求的处理流程

### 新增需求（REQ 条目新增后）

```bash
# 1. 在 requirement skill 侧创建新 REQ
bash skills/requirement/scripts/new-req.sh smart-college "教师-AI助教" --role 教师

# 2. 同步索引
bash skills/requirement/scripts/sync-map.sh smart-college

# 3. 在 prototype-design 侧增量生成
bash skills/prototype-design/scripts/generate.sh wireframe smart-college --req REQ-20260522-046
```

### 变更需求（REQ 条目内容修改后）

```bash
# 1. 修改 REQ-xxx.md 内容

# 2. 找到受影响的原型文件（查 meta/requirements-map.json）
jq '.mappings[] | select(.req_id == "REQ-20260522-001") | .files[]' meta/requirements-map.json

# 3. 重生成该模块
bash skills/prototype-design/scripts/revise-module.sh smart-college dashboard modules/学院领导/dashboard.html
```

### 删除/弃用需求

1. 在 requirement skill 侧将 REQ 状态改为 `deprecated`
2. 本 skill 不自动删除已有原型文件——只标记对应 mapping 为 `deprecated: true`
3. 人工决定是否清理

## 与 deploy-app skill 的集成

原型最终需要部署到 demo 服务器让客户浏览。集成方式：

```
prototype-design 生成
        ↓
docs-repos/<project>/prototype/  (本地文件)
        ↓
deploy-app static 模式
        ↓
/opt/demo/<project>/  (阿里云服务器)
        ↓
<project>.8.138.118.28.nip.io  (浏览器访问)
```

### 部署步骤

```bash
# Phase 5/6 实现，当前为占位
bash skills/deploy-app/scripts/deploy.sh demo <project>-prototype --skip-build
```

部署模式为 `static`（deploy-app Phase 6），直接 rsync `prototype/` 到 `/opt/demo/<project>/`。

## 配置说明

### config/projects.json（已注册项目）

```json
{
  "projects": {
    "smart-college": {
      "display_name": "智院",
      "modules": ["学院领导", "教师", "辅导员", "学生", "校友", "管理员"],
      "style": "wireframe",
      "initialized": false
    }
  }
}
```

### config/brand.json（品牌配置）

```json
{
  "brand_color": "#E8622C",
  "company_name": "权舆科技",
  "slogan": "AI造软件，快人一步",
  "default_style": "wireframe"
}
```

| 字段 | 说明 |
|------|------|
| `brand_color` | highfi/interactive 主题色 |
| `company_name` | 导航栏、页脚显示的公司名 |
| `slogan` | 主导航页 slogan |
| `default_style` | 未指定 `--style` 时使用 |

完整 schema 见 `config/schema.md`。

## Phase 路线图

| 阶段 | 状态 | 功能 |
|------|------|------|
| **Phase 1** | ✅ 当前 | 框架 + 自检 + 模板 + 脚本骨架 + 1 个示例输出 |
| **Phase 2** | ⏳ | wireframe 风格完整业务页面生成（按角色/模块拆文件） |
| **Phase 3** | ⏳ | highfi 风格（品牌色 + 真实数据 + 完整视觉） |
| **Phase 4** | ⏳ | interactive 风格（Tab/Modal/Chart 完整交互 + 弹窗联动） |
| **Phase 5** | ⏳ | 需求反写自动化（生成后自动更新 REQ 条目 related_files.prototype） |
| **Phase 6** | ⏳ | 与 deploy-app skill 集成（static 部署模式一键 demo） |

## 已知限制

- ❌ generate.sh Phase 1 仅骨架实现，跑通参数解析 + 1 个示例输出
- ❌ highfi / interactive 模板未实装（Phase 3/4）
- ❌ 需求反写（修改 REQ 条目 frontmatter）暂未自动执行
- ❌ 共享组件注入目前仅支持 `<iframe>` 方式，`fetch()` 方式待实现
- ❌ upgrade.sh 仅为占位脚本
- ❌ 无 Figma/Sketch 导出能力
- ❌ 单次生成页面数超过 10 个时需分批执行（AI 上下文限制）

## 维护人

- 主要：龙哥（邓云龙）
- AI 调度：呆呆
- 文档：本 README + setup.md + config/schema.md

---

## 快速启动

1. 首次使用：阅读 `setup.md` 完成初始化
2. 检查环境：`bash scripts/doctor.sh`
3. 初始化项目：`bash scripts/init.sh smart-college`
4. 生成原型：`bash scripts/generate.sh wireframe smart-college --role 学院领导`
5. 查看变更：`cat docs-repos/smart-college/prototype/meta/revisions.md`

---

## 📦 版本归档机制（v2 新增）

### 何时归档？

| 触发场景 | 归档 | 备注 |
|---------|------|------|
| 原型大改版（页面骨架重构/换风格） | ✅ 强制 | `archive.sh` 或 `promote.sh` |
| 客户验收某版本（v1.0 / v2.0 等） | ✅ 强制 | 用 `promote.sh` |
| 新增整个业务模块 | ✅ 推荐 | 模块上线前快照 |
| 单页面局部调整 | ❌ 不归档 | 只在 `meta/revisions.md` 加一条 |
| 单条 REQ 引发的微调 | ❌ 不归档 | 走 `revise-module.sh` |

### 归档目录命名规范

```
docs-repos/<project>/prototype/_archive/<版本号>-<日期>/
                                       └─ 例：v1.0-20260515/
                                       └─ 例：v2.0-20260601-内审版/
```

归档目录内会保留完整的：
- `_shared/`（全局样式、组件）
- `modules/`（各业务模块 HTML）
- `meta/`（版本元数据、修订记录）
- `index.html`（入口）

### 版本号语义（与 requirement skill 一致）

```
主版本.次版本.补丁  例：v2.1.0
│    │     └─ 补丁：拼写/小调整，文件数不变
│    └────── 次版本：新增/重写某模块，文件数变化
└─────────── 主版本：整体视觉/交互方案换代
```

### 三个核心脚本

```bash
# 1. 归档当前原型快照
bash skills/prototype-design/scripts/archive.sh <project> <version>

# 2. 比较两个版本差异
bash skills/prototype-design/scripts/diff-version.sh <project> <v1> <v2>

# 3. 升级为正式版本（归档 + 更新 meta/version.json + 加 revisions）
bash skills/prototype-design/scripts/promote.sh <project> <new-version>
```

### 不归档的轻量记录

| 变更类型 | 记录位置 |
|---------|---------|
| 单页面修订 | `meta/revisions.md` 追加一行 |
| 模块替换 | `revise-module.sh` 内部已记 |
| 子任务派发 | TASK-TRACKER.json |

### version.json 结构

`docs-repos/<project>/prototype/meta/version.json`

```json
{
  "current": "v2.0",
  "history": [
    {"version": "v2.0", "archived": true, "date": "2026-06-01", "archive_dir": "_archive/v2.0-20260601/"},
    {"version": "v1.0", "archived": true, "date": "2026-05-15", "archive_dir": "_archive/v1.0-20260515/"}
  ]
}
```

`current` 表示当前正在迭代的版本号，`null` 表示尚无正式版。

---

## 🆕 v3 新增能力（2026-05-23）

本次新增 6 个脚本 + 4 个 lib 库 + 4 大机制升级。聚焦"批量生成 / 双向映射 / 多版本并存 / 项目门户页"。

### 一、新增脚本（6 个）

#### 1. `generate.sh`（Phase 2 升级）—— 批量生成 + 智能模板

不再是"一次一个原型"，而是支持**按需求集合一次性批量生成**。
模板由 `lib/generate_batch.py` 根据 REQ 的 `category`/`screen_type` 自动选型。

5 个内置 wireframe 业务模板（`templates/wireframe/business/`）：

| 模板 | 适用场景 |
|------|---------|
| `workspace.html` | 工作台/角色首页（卡片+待办+快捷入口） |
| `list.html` | 列表页（搜索+筛选+表格+分页） |
| `detail.html` | 详情页（左信息右操作） |
| `form.html` | 表单页（分组+校验+提交） |
| `dashboard.html` | 数据看板（KPI+图表占位） |

> 高仿真（highfi）与可交互（interactive）后续按相同 schema 扩展。

#### 2. `diff-against-requirements.sh` —— 需求-原型差异检测

比对 `requirements/requirements-map.json`（活跃需求）与 `prototype/meta/requirements-map.json`（原型映射），输出三类问题：

- ❌ REQ 存在但无原型 → 需要新建
- 🗑 原型存在但 REQ 已 deprecated → 应归档
- ⏰ REQ.updated 晚于原型 generated_at → 可能需要更新

```bash
bash scripts/diff-against-requirements.sh <project>
# 退出码：0=无差异，1=有差异（适合 CI 报警）
```

#### 3. `generate-index.sh` —— 项目门户页生成

自动生成 `prototype/index.html`，作为整个项目原型的入口门户。

```bash
bash scripts/generate-index.sh <project>
```

**输入：**
- `requirements/requirements-map.json`（必需）
- `prototype/meta/requirements-map.json`（必需）
- `prototype/meta/versions.json`（可选，用于版本切换器）
- `prototype/meta/index-config.json`（可选，配置角色分组/排序/标题，缺失走默认）

**输出 Assertion：** 文件 > 8KB、含版本切换器、至少 1 个角色块。

详见下文【机制三：项目门户页】。

#### 4. `generate-mapping.sh` —— 需求-原型映射可视化

生成 `prototype/mapping.html`，把"REQ ↔ 原型文件"映射以可视化表格展示，方便评审与产品对齐。

```bash
bash scripts/generate-mapping.sh <project>
```

底层调用 `lib/render_mapping.py`，渲染时联动 REQ 的 status/priority 染色。

#### 5. `publish-version.sh` —— 多版本发布

把 `_archive/<version>/` 的归档快照"发布"到 `prototype/archive/<version>/`，让历史版本变成可在线访问的副本（而不仅是冷存档）。

```bash
bash scripts/publish-version.sh <project> <version>
# 例: bash scripts/publish-version.sh smart-college v3.0
```

发布后 `index.html` 的版本切换器会自动识别并加入新条目（需重跑 `generate-index.sh`）。

#### 6. `sync-back-refs.sh` —— 反向回填

把 `prototype/meta/requirements-map.json` 的 mapping，反向回填到对应 REQ 文件的 `frontmatter.related_files.prototype`。

```bash
bash scripts/sync-back-refs.sh <project> [--dry-run]
# 退出码：0=成功（或 dry-run 完成），1=出错或 post-check 不一致
```

**为什么需要：** REQ 是需求侧的唯一事实源，但生成原型时是"按 REQ 派生"。回填后，REQ 文件本身就能查到"我对应哪些原型页面"，闭环一致性。

> 已在 `generate.sh` 内部强制调用，确保生成后立刻同步。

#### 7. `write-large-file.sh` —— 通用大文件写入

绕过 OpenClaw `write` 工具 ~10KB 的实际限制，专用于写 HTML/CSS/JSON 等大型生成产物。

```bash
# 用法 1：从 stdin
cat <<'EOF' | bash scripts/write-large-file.sh /path/to/output.html
...content...
EOF

# 用法 2：从源文件
bash scripts/write-large-file.sh /path/to/output.html --from /tmp/source.html

# 用法 3：追加
bash scripts/write-large-file.sh /path/to/output.html --append
```

**特性：** 自动建父目录 / 写后校验 size > 0 / 输出写入摘要（路径+大小+前 3 行预览）。

> 主 Agent 与子 Agent 生成 >10KB 文件时必须用本脚本，**不要再用 write 工具**。

### 二、新增 lib 库（4 个）

| 文件 | 职责 |
|------|------|
| `lib/back_ref.py` | `sync-back-refs.sh` 的核心实现：解析 REQ frontmatter 并安全回填 |
| `lib/generate_batch.py` | `generate.sh` Phase 2 的批处理引擎，按 REQ 智能选模板 |
| `lib/generate_index.py` | `generate-index.sh` 的渲染器（HTML + 版本切换器 + 角色分组） |
| `lib/render_mapping.py` | `generate-mapping.sh` 的映射表渲染器 |

> lib 仅供脚本内部调用，外部用户应通过对应 `.sh` 入口使用。

### 三、四大新机制

#### 机制一：反向回填（Back-Ref）

**Why：** REQ 是需求事实源，但人手维护 `REQ.related_files` 会过时。生成原型时反向回填，REQ 文件永远知道"我对应哪些原型"。

**How：**
1. `generate.sh` 生成完原型，更新 `prototype/meta/requirements-map.json`
2. 自动调用 `sync-back-refs.sh`，把 mapping 写回每个 REQ.frontmatter.related_files.prototype
3. `doctor.sh` 做 post-check 验证一致性

**协作：** 与 `requirement` skill 的 `set-status.sh` / `doctor.sh` 形成闭环。

#### 机制二：多版本并存（Archive + Switch）

**Why：** 客户评审时常需要"既看新版又对照旧版"。

**How：**
1. `archive.sh` / `promote.sh` 把当前快照写入 `_archive/<version>-<date>/`（冷归档）
2. `publish-version.sh` 把 `_archive/<version>/` 复制到 `prototype/archive/<version>/`（可访问副本）
3. `generate-index.sh` 读 `meta/versions.json`，在门户页头部生成**版本切换器**
4. 用户在浏览器内可在 current / v3.0 / v2.0 自由切换

#### 机制三：项目门户页（Index）

**Why：** 原型多了之后需要一个入口聚合"所有角色 × 所有版本"。

**How：**
- `prototype/index.html` 作为入口，按角色分组卡片（如：管理端 / 教师端 / 学生端）
- `meta/index-config.json` 控制：标题、角色顺序、每个角色下显示哪些原型、是否隐藏 deprecated
- `meta/versions.json` 控制：版本切换器有哪些选项
- 任何 generate/promote/publish-version 后，重跑 `generate-index.sh` 即联动更新

**默认行为：** 即使没有 `index-config.json`，也会按 frontmatter.role 自动分组渲染。

#### 机制四：doctor.sh 增强（一致性 + UI 完整性）

`doctor.sh` 现在覆盖：

- **双向映射一致性**：REQ ↔ prototype map 必须双向对齐
- **UI 资产完整性**：每个原型页面必须能找到 `sidebar` 注入点、`styles.css`、`<title>`
- **standalone 校验**：原型 HTML 独立打开不能 404
- **联动 lint**：内部会调用 `requirement/scripts/lint.sh`，需求侧不通过原型 doctor 直接 fail

```bash
bash scripts/doctor.sh <project>
```

### 四、与其他 skill 的关系（更新）

- **`requirement`** → 提供 REQ 事实源；`prototype-design` 消费 REQ 并通过 `sync-back-refs.sh` 反向回填
- **`requirement/lint.sh`** → 被 `prototype-design/doctor.sh` 调用，保证需求侧合规
- **`dispatch-task`** → 派发"原型批量生成"任务时，必须带项目名 + REQ 范围（角色/阶段）
- **`deploy-app`** → 部署原型到演示环境时直接拷 `prototype/` 整目录（含 `index.html` + `archive/`）

### 五、常用命令速查（v3 新增部分）

```bash
# 批量生成（v3）
bash scripts/generate.sh <project> --role admin --batch

# 差异巡检
bash scripts/diff-against-requirements.sh <project>

# 反向回填 + dry-run
bash scripts/sync-back-refs.sh <project> --dry-run

# 发布历史版本到可访问目录
bash scripts/publish-version.sh <project> v3.0

# 生成项目门户页
bash scripts/generate-index.sh <project>

# 生成需求-原型映射表
bash scripts/generate-mapping.sh <project>

# 写超大 HTML
cat <<'EOF' | bash scripts/write-large-file.sh /abs/path/file.html
<html>...</html>
EOF
```

