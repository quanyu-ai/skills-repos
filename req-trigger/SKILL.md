---
name: req-trigger
description: 需求触发技能 - 用于明确接收和转化用户反馈/bug/需求为标准REQ条目
metadata: {"openclaw":{"emoji":"🎯"}}
---

# req-trigger - 需求触发技能 🎯

> 用于：龙哥哥说"智策首页404"，AI如何确定这是需求并自动记录？
> 核心：**明确触发机制** + **项目识别** + **自动登记**

---

## 🚦 触发方式（3种，必选其一）

### 方式1：斜杠命令（推荐）
```
/req 智策首页404修复
/req [-p 优先级] 项目名 - 需求描述
```

### 方式2：JSON格式
```
{"project":"smartops","title":"首页404修复","type":"bug","priority":"P1"}
```

### 方式3：固定前缀
```
[REQ] 智策首页404修复
[BUG] 智策订单加载慢
[FEEDBACK] 智策商品搜索功能需要
```

---

## 🔧 自动识别规则

收到输入后，AI需要：

1. **识别项目**：
   - 关键词："智策" → smartops
   - 关键词："晨曦" → chenxi-study
   - 关键词："智院" → smart-college
   - 明确指定：project=XXX

2. **识别类型**：
   - "bug/error/错误/问题" → type=bug
   - "需要/想要/希望/功能" → type=function
   - "优化/改进/调整" → type=optimization

3. **提取内容**：
   - 自动抽取核心需求描述
   - 缺失字段需要向用户确认

4. **生成REQ草案**：
   ```
   REQ-YYYYMMDD-NNN:
   - project: smartops
   - title: 智策首页404修复
   - type: bug
   - priority: P1 (或用户指定)
   - status: draft
   ```

5. **等待确认**：
   - 用户回复 `/approve` → 创建REQ
   - 用户回复 `/edit` → 修改后创建
   - 用户回复 `/cancel` → 取消

---

## 📋 与 requirement skill 的关系

| Skill | 职责 |
|-------|------|
| **req-trigger** | 接收/识别/转化用户输入 → 生成REQ草案 |
| **requirement** | 创建REQ文件/状态流转/索引维护 |
| **req-trigger → requirement** | req-trigger生成草案 → requirement正式创建 |

---

## 🔄 完整流程

```
龙哥哥：/req 智策首页404修复

AI（req-trigger技能）：
→ 识别 project=smartops
→ 识别 type=bug
→ 识别 priority=P1
→ 生成 REQ-20260525-004 草案
→ 条目：REQ-20260525-004: 智策首页404修复
→ 等待确认

龙哥哥：/approve

AI（requirement技能）：
→ 执行 new-req.sh 创建 REQ-20260525-004.md
→ 执行 sync-map.sh 更新索引
→ 返回：✓ REQ已创建
```

---

## 🎯 优势

1. **明确性**：龙哥哥主动触发，AI不会误解
2. **可追溯**：每个REQ都有明确来源和确认记录
3. **可自动化**：skill可以调用其他skill完成后续
4. **容错性**：缺失信息会向上确认，不会错误创建

---

## 🧪 测试场景

```
# 场景1：直接需求
龙：/req 智策首页404修复
→ AI: 生成草案，等待确认

# 场景2：带参数
龙：/req [-p P0] 智策登录功能必须修复
→ AI: 生成 P0 优先级草案，等待确认

# 场景3：项目明确
龙：/req [-p P1] 项目：晨曦学园 课程表显示错误
→ AI: 生成 smart-college 项目的草案

# 场景4：取消
龙：/req 智策首页404修复
龙：/cancel
→ AI: 已取消

# 场景5：编辑后创建
龙：/req 智策首页404修复
龙：/edit 首页返回404错误，用户无法访问
→ AI: 用新描述创建
```

---

## 📌 实施计划

1. 创建 req-trigger skill（本文件）
2. 在 AGENTS.md 添加 req-trigger 使用说明
3. AI启动时自动加载 req-trigger 技能
4. 测试并优化触发规则
