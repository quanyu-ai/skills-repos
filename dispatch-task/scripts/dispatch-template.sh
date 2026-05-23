#!/bin/bash
# dispatch-template.sh - 输出标准派单模板
#
# 用法：
#   bash dispatch-template.sh <type>
#   type: dev / deploy / test / proto / infra
#
# 输出：可直接复制粘贴到任务描述

set -euo pipefail

TYPE="${1:-help}"

case "$TYPE" in
    dev)
        cat <<'EOF'
## 任务 TASK-YYYYMMDD-NNN：<标题>

### 工作目录
`<项目绝对路径，如 /var/lib/openclaw/.openclaw/workspace/code-repos/xxx>`

### 当前状态（已内联）
- 文件：`<绝对路径>`
- 当前代码：
  ```
  <粘贴当前代码片段>
  ```

### 目标
- 改成：
  ```
  <粘贴目标代码>
  ```

### 完整执行链路
1. 编辑文件
2. `pnpm build`（或对应构建命令）
3. 本地测试 / 验证
4. `git add . && git commit -m "feat: ..." && git push`

### 环境信息
- 数据库：<连接串>
- 端口：<port>
- 容器：<container>

### 重要约束
- 大文件 (>10KB) 用 `skills/prototype-design/scripts/write-large-file.sh`
- 禁用 OpenClaw write 工具写 >10KB 文件（踩坑见 MEMORY.md 2026-05-23）
- 所有 shell 脚本 `set -euo pipefail`

预估 <N> 分钟。
EOF
        ;;
    deploy)
        cat <<'EOF'
## 任务 TASK-YYYYMMDD-NNN：部署 <服务名> 到 <环境>

### 目标环境
- 服务器：<IP> / <SSH 别名>
- 端口：<port>
- 域名：<domain>
- 部署路径：<绝对路径>
- 容器/进程名：<name>

### 步骤
1. 进入项目目录拉取最新代码
2. 构建产物：`pnpm build` 或 `docker build ...`
3. 执行部署脚本：`bash skills/deploy-app/scripts/<env>.sh <project>`
4. 健康检查：`curl -fsS <url>` 期望 200
5. 更新台账：
   - `knowledge-repos/management/DEPLOY-LOG.md` 追加部署记录
   - `knowledge-repos/management/INFRA-LEDGER.md` 更新资源状态

### 回滚预案
<必填：上一版镜像 tag / 备份目录 / 回滚命令>

预估 <N> 分钟。
EOF
        ;;
    test)
        cat <<'EOF'
## 任务 TASK-YYYYMMDD-NNN：测试 <模块/功能>

### 测试范围
- 目标 URL / 接口（内联清单）
- 测试账号（内联或指向 docs-repos）

### 测试用例（内联）
1. 用例 1：<输入> → <期望输出>
2. 用例 2：...

### 执行方式
- 手工 / Playwright / curl

### 报告位置
`docs-repos/<project>/test-reports/TASK-YYYYMMDD-NNN.md`

### 完成后
- git add + commit + push 报告
- 更新 TASK-TRACKER 状态

预估 <N> 分钟。
EOF
        ;;
    proto)
        cat <<'EOF'
## 任务 TASK-YYYYMMDD-NNN：生成 <模块> 原型

### 风格
- wireframe / highfi / interactive（三选一）

### 模块清单
- 模块 1：<功能描述 + 关键字段>
- 模块 2：<功能描述 + 关键字段>

### 输出目录
`<绝对路径，如 /var/lib/openclaw/.openclaw/workspace/code-repos/proto-xxx>`

### 工具
- 必须用 `skills/prototype-design/scripts/generate.sh`
- 写 HTML 必须用 `skills/prototype-design/scripts/write-large-file.sh`
- 禁用 OpenClaw write 工具

### 完成后
- 启动本地预览 / 部署到 proto 环境
- git commit + push

预估 <N> 分钟。
EOF
        ;;
    infra)
        cat <<'EOF'
## 任务 TASK-YYYYMMDD-NNN：<标题>

### 范围（明确写允许 / 禁止）
- ✅ 允许修改：<list>
- ❌ 禁止修改：<list>

### 工作目录
`<绝对路径>`

### 必做测试
- 测试 1：<命令> 期望 <结果>
- 测试 2：<命令> 期望 <结果>

### 完成后必做
- 更新 `knowledge-repos/management/INFRA-LEDGER.md`
- git commit + push（如在 git 仓库内，先 `git rev-parse --show-toplevel` 确认归属）

### 重要约束
- 大文件用 write-large-file.sh
- `set -euo pipefail`

预估 <N> 分钟。
EOF
        ;;
    help|*)
        cat <<'EOF'
dispatch-template.sh - 输出标准派单模板

用法：bash dispatch-template.sh <type>

可选 type：
  dev     - 开发任务（写/改代码 + build + commit）
  deploy  - 部署任务（构建 + 上线 + 健康检查 + 更新台账）
  test    - 测试任务（用例 + 报告）
  proto   - 原型任务（用 prototype-design skill）
  infra   - 基础设施任务（脚本/配置/工作区调整）

示例：bash dispatch-template.sh deploy > /tmp/task.md
EOF
        exit 0
        ;;
esac
