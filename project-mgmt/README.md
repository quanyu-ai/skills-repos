# project-mgmt README

把"项目"做成一份长期可追踪的档案。

## 文件总览
- `SKILL.md` - 红线 + 使用场景
- `setup.md` - 首次安装 / 修复指南
- `scripts/` - 全部命令脚本
- `templates/` - profile / milestones / decisions / incidents / metrics 初始模板

## 一分钟上手
```bash
SKILL_DIR=/var/lib/openclaw/.openclaw/workspace/skills/project-mgmt

# 1. 自检
bash $SKILL_DIR/scripts/doctor.sh

# 2. 新建一个项目档案
bash $SKILL_DIR/scripts/new-project.sh demo-project \
  --display-name "示例项目" --client "演示" --stage planning

# 3. 看仪表盘
bash $SKILL_DIR/scripts/dashboard.sh
```

## 数据落地位置
`/var/lib/openclaw/.openclaw/workspace/knowledge-repos/projects/`
