# ADR — Architecture Decision Records

## 什么是 ADR

ADR (Architecture Decision Record) 记录每一条**重要的技术决策**及其**背景与权衡**。

ADR 不是设计文档，而是"为什么这么选"的留痕。让未来的自己/团队能快速理解**当初为什么走这条路**。

## 文件命名

```
ADR-001-<short-title>.md
ADR-002-<short-title>.md
...
```

- 编号三位数字，递增，永不复用
- 标题英文小写连字符，简短（不超 4 个词）

示例：
- `ADR-001-tech-stack.md`
- `ADR-002-database-choice.md`
- `ADR-003-deployment-strategy.md`

## 状态流转

```
proposed → accepted → (deprecated | superseded by ADR-NNN)
```

- **proposed**：草稿，待评审
- **accepted**：已采纳
- **deprecated**：已废弃但保留历史
- **superseded**：被新 ADR 替代（需写明替代者编号）

## 何时新增 ADR

✅ 一定要写 ADR 的情况：
- 选型决策（前端框架、DB、消息队列、部署方案）
- 跨模块协议变化（RESTful → tRPC、同步 → 异步）
- 性能/安全相关的重大权衡
- 与"看起来更简单的方案"做了不同选择

❌ 不用写 ADR 的情况：
- 单纯的实现细节（变量命名、函数拆分）
- 临时的 bugfix

## 模板

见 `./_template.md`。

## 快速新增

```bash
PROJECT=smart-college
ADR_DIR=docs-repos/$PROJECT/solution/adr
NEXT=$(printf "%03d" $(($(ls $ADR_DIR/ADR-*.md 2>/dev/null | wc -l) + 1)))
cp skills/solution-design/templates/adr-template.md $ADR_DIR/ADR-${NEXT}-<title>.md
```
