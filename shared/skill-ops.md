---
name: skill-ops
description: 技能操作规范。当需要创建、编辑、安装、更新技能文件时激活。
---

# 技能操作规范（共享）

## 核心规则

1. **原始档案（skills-repos）是唯一源头**，不在本地单独创建技能
2. 改技能 = 先改原始档案 → push → 再同步到本地
3. 新建技能必须确定分类（shared/roles/modes/项目专用）
4. SKILL.md 的 `description` 决定激活时机，必须写准确

## 快速操作

### 新建技能
```
确定分类 → 在 skills-repos 创建目录+SKILL.md → push → 安装到本地 → 更新README
```

### 编辑技能
```
改 skills-repos 原始档案 → push → 同步到本地 → 通知其他协作者
```

### 安装技能
```
git pull skills-repos → cp 对应目录到 workspace/skills/
```

## 完整规范

详见 `guides/skill-management.md`
