# Schema — REQ-*.md frontmatter 字段规范

> 所有需求条目的 frontmatter 必须遵循本规范。**字段名严格按本表，不要私自改名。**

---

## 顶层字段

```yaml
---
id:              <string, required>   # REQ-YYYYMMDD-NNN
title:           <string, required>   # 一句话标题
status:          <enum,   required>   # draft|reviewing|approved|implementing|done|deprecated
phase:           <enum,   required>   # 一阶段|二阶段|unscheduled
priority:        <enum,   required>   # P0|P1|P2
category:        <enum,   required>   # 业务功能|数据需求|非功能需求
role:            <string, optional>   # 角色名（学院领导|教师|辅导员|学生|校友|系统管理员|...）
source_doc:      <string, optional>   # 来源文档文件名
source_section:  <string, optional>   # 来源章节号
created:         <date,   required>   # YYYY-MM-DD
updated:         <date,   required>   # YYYY-MM-DD
depends_on:      <string[], optional> # 依赖的 REQ-id 列表
related_files:
  prototype:     <string[], optional> # 原型文件路径
  design:        <string[], optional> # 设计文档路径
  code:          <string[], optional> # 实现代码路径
  test:          <string[], optional> # 测试用例路径
deprecated_reason: <string, optional> # status=deprecated 时填写
---
```

---

## 正文必填章节

每条 REQ 的正文（frontmatter 之后）至少包含：

```markdown
# <title>

## 一句话概述
<summary，1 行内说清做什么>

## 业务背景
<可选，3-5 行>

## 功能要点
- <要点 1>
- <要点 2>
...

## 验收标准（acceptance_criteria）
- [ ] <验收点 1>
- [ ] <验收点 2>
...

## 备注
<可选>
```

---

## 命名规则

### id

- 格式：`REQ-YYYYMMDD-NNN`
- YYYYMMDD：创建日期
- NNN：当日序号，从 `001` 起，最多 999
- 一旦分配，**绝不可变**

### title

- 推荐格式：`<角色>-<功能名>`，如 `学院领导-工作台`
- 长度 ≤ 30 字符
- 不含特殊符号（/ \ : * ? " < > |）

### related_files 路径

- 相对工作区根目录 `/var/lib/openclaw/.openclaw/workspace/` 的路径
- 例：`code-repos/smart-college/src/pages/leader/Workbench.tsx`

---

## 状态机

```
draft → reviewing → approved → implementing → done
                          │
                          └─→ deprecated
```

- `draft → reviewing`：作者完成初稿，提交评审
- `reviewing → approved`：评审通过
- `reviewing → draft`：评审打回，需要补充
- `approved → implementing`：开始开发，TASK-TRACKER 应有对应 task
- `implementing → done`：上线验收通过
- `* → deprecated`：弃用（不再做或被新 REQ 取代）

---

## phase 取值

| 值 | 说明 |
|----|------|
| `一阶段` | 第一期交付（如 V3.0 中的一阶段功能） |
| `二阶段` | 第二期交付 |
| `unscheduled` | 尚未排期 |

---

## priority 取值

| 值 | 含义 | 示例 |
|----|------|------|
| `P0` | 核心功能，必须有 | 工作台、驾驶舱、一张表 |
| `P1` | 日常功能，应有 | 流程审批、班级看板 |
| `P2` | 增值功能，可选 | 场地预约、个性化配置 |

---

## category 取值

| 值 | 说明 |
|----|------|
| `业务功能` | 用户可见的功能页面/交互 |
| `数据需求` | 数据模型、字段、统计口径 |
| `非功能需求` | 性能、安全、合规、可用性 |

---

## 校验

- frontmatter 必须是合法 YAML
- `sync-map.sh` 解析失败时会在 stderr 报错并跳过该条
- Phase 2 将引入 `lint-req.sh` 做字段级校验
