# 权舆软件工程技能插件

`quanyu-ai/skills-repos` 是唯一编辑来源。插件 `quanyu-software-engineering@quanyu-skills` 通过 `.codex-plugin/plugin.json` 引用本仓库现有15个技能目录，不复制源码，不打包其他角色/部署技能，不引入 MCP 或 hooks。Codex 安装缓存是固定版本的分发副本，不在缓存中修改技能。

## 安装与更新

```sh
codex plugin marketplace add quanyu-ai/skills-repos --ref main
codex plugin add quanyu-software-engineering@quanyu-skills
codex plugin list --marketplace quanyu-skills --json
```

在 Codex 插件目录选择“权舆共享技能”查看和管理。首次安装如桌面清单未刷新，待当前任务到安全点后重新打开界面/新会话，不终止在途开发或重启业务服务。

更新在共享库改源、正常 PR 合并并更新插件版本，然后执行 `codex plugin marketplace upgrade quanyu-skills` 与 `codex plugin add quanyu-software-engineering@quanyu-skills`。同一机器只启用一个该插件版本，不再向每项目复制15项技能。

## 唯一当前版本与主调度

只启用当前 `quanyu-software-engineering`，不保留旧名称兼容链接或项目技能正文副本。升级确认新版本可发现后，用现有采用脚本更新唯一当前链接；旧正文压缩封存并移出自动发现路径，不重新创建wrapper。现役业务无需为技能升级重启。

`main-coordinator`按项目真实职责推进用户结果，不强制额外调度者、台账、固定表单或多Agent。原需求与业务权威留在各项目。

## 项目拓展与边界

通用方法由插件维护；各项目 `AGENTS.md` 指向本项目的需求、架构、测试、发布及交付记录，承载领域语义、角色、环境和优先级。原文件和负责人不变，不新增扩展注册表或审批。可增加不同名称的项目技能，不用同名副本覆盖共享源。按任务选用，不强制15项串行执行。

迁移已有项目，先沿官方入口确认当前插件已安装启用，再使用本库脚本（Python 3.11+）：

```sh
python3 scripts/adopt-engineering-plugin.py --plugin-root /actual/installed/plugin/root --project /absolute/project
```

脚本核对已安装版本，更新唯一稳定入口 `~/.codex/shared-skills/quanyu-software-engineering`；将旧项目通用技能和原始历史逐字校验压缩后移出读取/发现路径，移除对应旧路径配置，不创建兼容 SKILL 或第二份正文。项目业务规则保留原处。普通目录占用别名时先核来源，不直接覆盖。

后续官方升级后仅用 `--plugin-root /new/installed/root` 切换稳定入口，不逐项目复制技能。退休旧插件名称、旧缓存和旧维护链接，必要历史压缩封存。当前任务不重启，不重新执行已通过步骤；已载入上下文不会追溯清除，下一次实际调用读取当前唯一入口。

## 验证

manifest 的15个目录为发布清单：目录必须存在、技能名唯一、引用不离开仓库。实际 Codex 插件安装和技能发现才证明已加载，文件存在不等于生效。共享源不放项目业务规则或秘密。

## 独立 UI 插件

`quanyu-ui@quanyu-skills` 使用 `quanyu-ui/.codex-plugin/plugin.json`，按任务提供三个技能：

- `ui-standards`：维护规范、正反例和组件接入要求。
- `ui-design`：设计页面视觉层级、布局、密度与状态呈现。
- `ui-review`：观看并操作实际界面，记录问题和定向复验。

```sh
codex plugin marketplace upgrade quanyu-skills
codex plugin add quanyu-ui@quanyu-skills
codex plugin list --marketplace quanyu-skills --json
```

项目通过现有 `AGENTS.md`、设计规范索引或专属技能提供品牌、组件、目标端和业务边界；无需固定扩展文件名。无项目扩展时采用当前需求、已确认设计及可用组件，明确影响任务的假设。按需参考[项目扩展示例](../quanyu-ui/project-extension-examples/smart-college-ui-quality.md)，不自动给其他项目套用该示例。

工程插件继续负责业务交互原型与流程复核，UI 插件负责规范与实际视觉质量；两者可独立使用，不强制串行或安装另一个插件。插件不新增 MCP、hooks、业务权限或发布门禁。合并、安装、技能发现和实际消费分别核验；不强制重启在途会话或修改其他项目。

### 可选设计语言

`ui-design`按需加载[语言入口](../quanyu-ui/ui-design/references/design-languages/index.md)，提供沉稳商务、科技纵深、浅色空间三个参考。`ui-review`检查选中语言的材质/密度约束，`ui-standards`维护项目采用和组件映射。没有新增第四个自动技能、MCP、hooks、字体依赖或全局主题；已有项目不随插件升级换肤。

项目在原规范中记录所选语言与本项目依据，具体Token和业务规则仍以项目权威为准。三种参考不带示例业务、记录ID、端口、Figma文件或通过状态。源码版本、PR合并、安装版本、技能发现与实际任务使用分别核验；不为加载更新重启在途任务。
