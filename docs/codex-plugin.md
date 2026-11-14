# 权舆工程技能插件

`quanyu-ai/skills-repos` 是唯一编辑来源。插件 `quanyu-engineering@quanyu-skills` 通过 `.codex-plugin/plugin.json` 引用本仓库现有14个技能目录，不复制源码，不打包其他角色/部署技能，不引入 MCP 或 hooks。Codex 安装缓存是固定版本的分发副本，不在缓存中修改技能。

## 安装与更新

```sh
codex plugin marketplace add quanyu-ai/skills-repos --ref main
codex plugin add quanyu-engineering@quanyu-skills
codex plugin list --marketplace quanyu-skills --json
```

在 Codex 插件目录选择“权舆共享技能”查看和管理。首次安装如桌面清单未刷新，待当前任务到安全点后重新打开界面/新会话，不终止在途开发或重启业务服务。

更新在共享库改源、正常 PR 合并并更新插件版本，然后执行 `codex plugin marketplace upgrade quanyu-skills` 与 `codex plugin add quanyu-engineering@quanyu-skills`。同一机器只启用一个该插件版本，不再向每项目复制14项技能。

## 项目拓展与边界

通用方法由插件维护；各项目 `AGENTS.md` 指向本项目的需求、架构、测试、发布及交付记录，承载领域语义、角色、环境和优先级。原文件和负责人不变，不新增扩展注册表或审批。可增加不同名称的项目技能，不用同名副本覆盖共享源。按任务选用，不强制14项串行执行。

迁移已有项目，先确认插件已安装、14项可发现及源版本一致，再用 `~/.codex/config.toml` 禁用旧技能的**精确绝对路径**，不能按 name 禁用（会同时禁用插件）：

```toml
[[skills.config]]
path = "/absolute/project/.agents/skills/requirement/SKILL.md"
enabled = false
```

在途任务还会明确读取旧路径时，使用本库的兼容迁移脚本（Python 3.11+）：

```sh
python3 scripts/adopt-engineering-plugin.py --plugin-root /actual/installed/plugin/root --project /absolute/project
```

脚本先核该插件版本已安装并启用，归档原技能而不删除；旧 `SKILL.md` 变为仅指向共享原文的兼容入口，自动发现按旧绝对路径禁用。辅助目录链接同一安装源，项目规则保持原处。原文件备份在项目 `.agents/shared-skills-legacy/`，不在自动发现目录，不作为日常编辑源。

实测不能把整个旧技能目录直接链接到插件再按旧路径禁用：客户端会解析真实路径，导致插件技能一起禁用。因此旧 `SKILL.md` 必须保持普通的短引用文件。不要把技能正文复制进这个兼容文件。

所有兼容引用通过 `~/.codex/shared-skills/quanyu-engineering` 这一维护链接指向已安装插件。更新插件后仅执行 `python3 scripts/adopt-engineering-plugin.py --plugin-root /new/installed/root` 更新此链接，各已迁移项目不再各自升级副本。当前任务不重启，下一正常会话核唯一发现；已载入旧上下文不会被追溯清除。

## 验证

manifest 的14个目录为发布清单：目录必须存在、技能名唯一、引用不离开仓库。实际 Codex 插件安装和技能发现才证明已加载，文件存在不等于生效。共享源不放项目业务规则或秘密。
