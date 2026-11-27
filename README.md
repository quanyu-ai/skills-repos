# 权舆自建软件工程与UI技能

目的：用户看得懂、能够用、业务信息清晰、能够解决问题。完整方法见[用户结果与必要检查](docs/software-engineering-system.md)。

当前工程插件直接提供15项通用技能，UI插件提供3项；按任务选用，不构成固定流水线。正式入口以两个plugin.json为准，唯一编辑源是本仓库，当前官方安装为分发副本。不要用旧角色入口、缓存版本或项目wrapper建立另一套规则。

需求/方案/原型明确用户问题和可观察结果；实现计划与开发补齐能力；测试/评审按实际使用判断；主调度及交付核验追到原任务完成。类型、局部PASS、接线和安装不是业务交付。旧director/product-designer/deployer入口只指向当前方法，不维护重复规范。

`deploy-app`、`database-config`和`dispatch-task`是已采用项目可选的操作适配，不是全项目强制工具或前置。未改动的第三方导入（skill-vetter、openclaw-skill-debugger、self-improving、skill-template）保其来源，不当自建规则推给项目。

安装更新见[插件说明](docs/codex-plugin.md)。已有记录复用，不新建采用报告、台账或额外审批。
