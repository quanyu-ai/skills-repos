# Setup — requirement Skill 首次使用引导

> 本文档由 `doctor.sh` 返回 `NEED_SETUP` 时触发阅读。
> 全程预计 3 分钟。本 skill 不涉及任何系统级配置，纯本地文件操作。

---

## Step 1：系统依赖

```bash
sudo yum install -y jq pandoc
# 或 Ubuntu: sudo apt-get install -y jq pandoc
```

| 工具 | 用途 |
|------|------|
| `jq` | JSON 索引读写 |
| `pandoc` | docx → markdown 解析（import-doc.sh 用） |

## Step 2：确认 docs-repos 存在

```bash
ls /var/lib/openclaw/.openclaw/workspace/docs-repos/
```

至少应该看到要管理的项目目录（如 `smart-college`、`chenxi-study`）。

如果项目目录不存在，先创建：
```bash
mkdir -p /var/lib/openclaw/.openclaw/workspace/docs-repos/<project>/requirements
```

## Step 3：跑一次 doctor

```bash
bash /var/lib/openclaw/.openclaw/workspace/skills/requirement/scripts/doctor.sh
```

期望输出：
```
READY
```

## Step 4：创建第一条需求（验证）

```bash
cd /var/lib/openclaw/.openclaw/workspace
bash skills/requirement/scripts/new-req.sh smart-college "测试需求-验证 skill" \
    --role 测试 --phase 一阶段 --priority P2
```

期望输出形如：
```
✓ Created: docs-repos/smart-college/requirements/REQ-20260522-001.md
```

然后检查文件：
```bash
cat docs-repos/smart-college/requirements/REQ-*.md | head -30
```

## Step 5：同步索引

```bash
bash skills/requirement/scripts/sync-map.sh smart-college
```

会生成两个文件：
- `docs-repos/smart-college/requirements/requirements-map.json`（机读）
- `docs-repos/smart-college/requirements/INDEX.md`（人读）

## Step 6：列表验证

```bash
bash skills/requirement/scripts/list-req.sh smart-college
```

应该能看到刚刚创建的那条需求。

## 完成后

- ✅ skill 就绪
- ✅ 可以开始正常使用 new/list/sync/import

---

## 常见问题

### Q1：编号冲突怎么办？

`new-req.sh` 会自动扫描当天已有的 `REQ-YYYYMMDD-*` 文件，从最大 NNN+1 自增。
**如果手动建过文件且编号不连续，自增仍然找最大值+1，不补洞。**

### Q2：可以手动改 .md 文件吗？

可以。修改后跑 `sync-map.sh` 重建索引即可。但建议保持 frontmatter 字段完整。

### Q3：要删除一条需求怎么办？

**不要直接删 .md 文件**。改 frontmatter `status: deprecated` 并加 `deprecated_reason` 字段。
保留历史可追溯。
