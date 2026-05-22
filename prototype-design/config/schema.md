# prototype-design 配置字段 Schema

> 配置文件位于 `skills/prototype-design/config/`。

---

## projects.json

注册项目元信息。

```json
{
  "projects": {
    "<project-key>": {
      "display_name": "<显示名>",
      "modules": ["角色1", "角色2", ...],
      "style": "wireframe|highfi|interactive",
      "initialized": true|false,
      "notes": "<备注>"
    }
  }
}
```

| 字段 | 必填 | 说明 |
|------|------|------|
| `projects.<key>` | ✅ | 项目 key，必须与 `docs-repos/<key>/` 目录名一致 |
| `display_name` | ✅ | 项目中文显示名 |
| `modules` | ✅ | 该项目的角色/模块列表（用于主导航生成） |
| `style` | ✅ | 当前默认风格 |
| `initialized` | ✅ | 是否已运行过 init.sh |
| `notes` | 否 | 自由备注 |

---

## brand.json

品牌配置（适用于 highfi/interactive 风格）。

```json
{
  "brand_color": "#E8622C",
  "company_name": "权舆科技",
  "slogan": "AI造软件，快人一步",
  "default_style": "wireframe"
}
```

| 字段 | 必填 | 说明 |
|------|------|------|
| `brand_color` | ✅ | 主品牌色（hex） |
| `company_name` | ✅ | 导航/页脚显示的公司名 |
| `slogan` | 否 | 主导航 slogan |
| `default_style` | ✅ | 未指定 `--style` 时使用 |

---

## meta/requirements-map.json（生成产物）

每个项目原型目录下的 `meta/requirements-map.json` 由本 skill 维护，记录"REQ ↔ HTML"映射。

```json
{
  "project": "<project-key>",
  "style": "wireframe|highfi|interactive",
  "updated": "<ISO8601 timestamp>",
  "mappings": [
    {
      "req_id": "REQ-YYYYMMDD-NNN",
      "title": "<需求标题>",
      "role": "<角色>",
      "files": ["modules/<role>/<module>.html"],
      "generated_at": "<ISO8601 timestamp>",
      "deprecated": false
    }
  ]
}
```

| 字段 | 说明 |
|------|------|
| `project` | 项目 key |
| `style` | 当前生成风格 |
| `updated` | 最后一次更新时间 |
| `mappings[]` | 每条 REQ 对应的原型文件列表 |
| `mappings[].req_id` | 关联的需求 ID |
| `mappings[].files[]` | 该 REQ 对应的 HTML 文件路径（相对 prototype/） |
| `mappings[].deprecated` | 若 REQ 已弃用则为 true，但文件保留 |
