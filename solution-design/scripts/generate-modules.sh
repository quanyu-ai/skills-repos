#!/bin/bash
# generate-modules.sh - 从 REQ 自动拆模块草稿
#
# 用法：
#   bash generate-modules.sh <project> [--dry-run]
#   例：bash generate-modules.sh smart-college
#   例：bash generate-modules.sh smart-college --dry-run
#
# 行为：
#   1. 读取项目的需求文件
#   2. 根据关键词和逻辑关系自动识别模块
#   3. 为每个模块创建基本的文件结构
#   4. 生成初步的设计文档和需求关联
#
# 注意：
#   - 这是一个辅助工具，生成的模块草稿需要人工审核和优化
#   - --dry-run 选项只会显示识别到的模块，不会实际创建文件

set -euo pipefail

SKILL_DIR="$(cd "$(dirname "$0")/.." && pwd)"
WORKSPACE_DIR="$(cd "$SKILL_DIR/../.." && pwd)"

DRY_RUN=false

# 参数处理
if [ $# -lt 1 ]; then
    echo "❌ 用法: bash generate-modules.sh <project> [--dry-run]"
    echo "   例: bash generate-modules.sh smart-college"
    echo "   例: bash generate-modules.sh smart-college --dry-run"
    exit 1
fi

PROJECT="$1"

if [ "$#" -ge 2 ] && [ "$2" == "--dry-run" ]; then
    DRY_RUN=true
    echo "🔍 执行 dry run 模式，不会实际创建文件"
fi

PROJECT_DIR="$WORKSPACE_DIR/docs-repos/$PROJECT"

# 前置检查
if [ ! -d "$PROJECT_DIR" ]; then
    echo "❌ 项目目录不存在: $PROJECT_DIR"
    exit 1
fi

SOLUTION_DIR="$PROJECT_DIR/solution"
if [ ! -d "$SOLUTION_DIR" ]; then
    echo "❌ 方案设计目录不存在: $SOLUTION_DIR"
    echo "   请先运行 bash $SKILL_DIR/scripts/init-solution.sh $PROJECT"
    exit 1
fi

REQUIREMENTS_DIR="$PROJECT_DIR/requirements"
if [ ! -d "$REQUIREMENTS_DIR" ]; then
    echo "❌ 需求目录不存在: $REQUIREMENTS_DIR"
    exit 1
fi

MODULES_DIR="$SOLUTION_DIR/modules"

# 识别模块的关键词列表
MODULE_KEYWORDS=(
    "用户管理" "权限管理" "角色管理" "登录认证" "注册" "用户信息"
    "课程管理" "教学管理" "学习管理" "成绩管理" "作业管理"
    "班级管理" "学生管理" "教师管理" "员工管理"
    "资源管理" "文件管理" "文档管理" "资料管理" "素材管理"
    "数据统计" "报表分析" "数据分析" "数据可视化"
    "通知公告" "消息管理" "通信管理" "邮件管理" "短信管理"
    "系统设置" "配置管理" "参数管理" "安全管理"
    "课程表" "日程管理" "时间管理" "考勤管理" "签到管理"
    "考试管理" "测试管理" "评估管理" "问卷管理"
    "论坛" "社区" "讨论" "社交" "互动"
    "搜索" "查询" "检索" "查找"
    "支付" "缴费" "收费" "财务" "账单"
)

# 辅助函数：生成模块名称
generate_module_name() {
    local name="$1"
    # 将中文名称转换为小写字母，并将空格和特殊字符替换为连字符
    local module_name=$(echo "$name" | iconv -t ASCII//TRANSLIT | sed 's/[^a-zA-Z0-9]/-/g' | tr -s '-' | tr '[:upper:]' '[:lower:]' | sed 's/^-*//;s/-*$//')
    echo "$module_name"
}

# 1. 扫描需求文档，识别潜在的模块
echo "1. 扫描需求文档，识别潜在的模块..."
IDENTIFIED_MODULES=()
for req_file in "$REQUIREMENTS_DIR"/*.md; do
    if [ -f "$req_file" ]; then
        req_content=$(cat "$req_file")
        
        # 使用关键词匹配识别模块
        for keyword in "${MODULE_KEYWORDS[@]}"; do
            if grep -q "$keyword" "$req_file"; then
                module_name=$(generate_module_name "$keyword")
                
                # 检查是否已识别到该模块
                if ! printf '%s\n' "${IDENTIFIED_MODULES[@]}" | grep -q -E "^${module_name}$"; then
                    IDENTIFIED_MODULES+=("$module_name")
                    if $DRY_RUN; then
                        echo "   - 识别到模块: $module_name (关键词: $keyword)"
                    fi
                fi
            fi
        done
    fi
done

if [ ${#IDENTIFIED_MODULES[@]} -eq 0 ]; then
    echo "⚠️  未识别到任何模块，可能需要调整关键词列表"
    exit 1
fi

# 2. 统计需求文档
total_reqs=$(ls -1 "$REQUIREMENTS_DIR"/*.md 2>/dev/null | wc -l)

echo "2. 分析完成"
echo "   需求文档数量: $total_reqs"
echo "   识别到的模块数量: ${#IDENTIFIED_MODULES[@]}"

if $DRY_RUN; then
    echo -e "\n🔍 识别到的模块清单:"
    for module in "${IDENTIFIED_MODULES[@]}"; do
        echo "   - $module"
    done
    echo -e "\n✅ Dry run 完成，未创建任何文件"
    exit 0
fi

# 3. 为每个模块创建文件结构
echo "3. 为每个模块创建文件结构..."
for module_name in "${IDENTIFIED_MODULES[@]}"; do
    module_dir="$MODULES_DIR/$module_name"
    
    if [ -d "$module_dir" ]; then
        echo "   - 模块 $module_name 已存在，跳过"
        continue
    fi
    
    # 创建模块目录
    mkdir -p "$module_dir"
    
    # 创建 design.md 文件
    cat > "$module_dir/design.md" <<EOF
# $module_name 模块设计文档

## 概述

该模块负责处理与 $module_name 相关的功能。

## 功能范围

- 描述该模块的功能范围

## 架构设计

- 描述该模块的架构设计

## 核心组件

- 列出该模块的核心组件

## 数据模型

- 描述该模块的数据模型

## 接口设计

- 描述该模块的接口设计

## 业务流程

- 描述该模块的业务流程
EOF
    
    # 创建 reqs.json 文件
    cat > "$module_dir/reqs.json" <<EOF
{
  "reqs": []
}
EOF
    
    # 创建 apis.json 文件
    cat > "$module_dir/apis.json" <<EOF
{
  "apis": []
}
EOF
    
    echo "   - 模块 $module_name 创建完成"
done

# 4. 更新 modules-draft.md 文件
cat > "$SOLUTION_DIR/modules-draft.md" <<EOF
# 模块拆分草稿

本文件是通过 generate-modules.sh 脚本自动生成的模块拆分建议，需要人工审核和优化。

## 识别到的模块

EOF

for module_name in "${IDENTIFIED_MODULES[@]}"; do
    cat >> "$SOLUTION_DIR/modules-draft.md" <<EOF
### $module_name

#### 功能概述

该模块负责处理与 $module_name 相关的功能。

#### 潜在的需求关联

EOF
done

# 5. 运行 sync-solution-map.sh 来更新映射关系
if [ -f "$SKILL_DIR/scripts/sync-solution-map.sh" ]; then
    echo "4. 更新解决方案映射关系..."
    bash "$SKILL_DIR/scripts/sync-solution-map.sh" "$PROJECT"
else
    echo "⚠️  sync-solution-map.sh 脚本不存在，无法更新映射关系"
fi

echo -e "\n✅ 模块拆分完成"
echo "   已创建 ${#IDENTIFIED_MODULES[@]} 个模块"
echo "   文件结构已生成"
echo "   请在 $MODULES_DIR 目录中查看和优化模块设计"

exit 0
