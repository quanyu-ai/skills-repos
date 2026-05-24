#!/bin/bash
# diff-against-reqs.sh - 需求变更时的方案漂移告警
#
# 用法：
#   bash diff-against-reqs.sh <project> [--dry-run]
#   例：bash diff-against-reqs.sh smart-college
#   例：bash diff-against-reqs.sh smart-college --dry-run
#
# 行为：
#   1. 比较需求文档与方案设计的一致性
#   2. 检查需求变更是否已反映在方案设计中
#   3. 识别方案设计中可能与需求不符的地方
#   4. 生成漂移报告，提示需要更新的部分

set -euo pipefail

SKILL_DIR="$(cd "$(dirname "$0")/.." && pwd)"
WORKSPACE_DIR="$(cd "$SKILL_DIR/../.." && pwd)"

DRY_RUN=false

# 参数处理
if [ $# -lt 1 ]; then
    echo "❌ 用法: bash diff-against-reqs.sh <project> [--dry-run]"
    echo "   例: bash diff-against-reqs.sh smart-college"
    echo "   例: bash diff-against-reqs.sh smart-college --dry-run"
    exit 1
fi

PROJECT="$1"

if [ "$#" -ge 2 ] && [ "$2" == "--dry-run" ]; then
    DRY_RUN=true
    echo "🔍 执行 dry run 模式，不会实际创建报告文件"
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
    exit 1
fi

REQUIREMENTS_DIR="$PROJECT_DIR/requirements"
if [ ! -d "$REQUIREMENTS_DIR" ]; then
    echo "❌ 需求目录不存在: $REQUIREMENTS_DIR"
    exit 1
fi

# 报告文件位置
REPORT_FILE="/tmp/diff-report.txt"

# 临时文件
TEMP_FILE=$(mktemp /tmp/diff-against-reqs.XXXXXX)
TEMP_REPORT=$(mktemp /tmp/diff-report.XXXXXX)

# 函数：写入报告内容
write_report() {
    if $DRY_RUN; then
        echo "$1"
    else
        echo "$1" >> "$TEMP_REPORT"
    fi
}

# 函数：执行需求文档与方案设计的差异检查
check_requirements_solution_diff() {
    write_report "=== 需求变更与方案设计差异报告 ==="
    write_report "项目名称: $PROJECT"
    write_report "生成时间: $(date '+%Y-%m-%d %H:%M:%S')"
    write_report ""

    # 1. 检查需求文档的数量与方案设计中关联的需求数量是否一致
    write_report "1. 需求文档与方案设计关联检查"
    write_report "--------------------------------"
    
    local total_reqs=$(find "$REQUIREMENTS_DIR" -name "*.md" | wc -l)
    local reqs_in_solution=0
    if [ -f "$SOLUTION_DIR/solution-map.json" ]; then
        reqs_in_solution=$(jq -r '.req_module_map | length' "$SOLUTION_DIR/solution-map.json")
    fi

    write_report "总需求文档数量: $total_reqs"
    write_report "方案设计中关联的需求数量: $reqs_in_solution"
    
    if [ "$total_reqs" -gt "$reqs_in_solution" ]; then
        write_report "⚠️  警告: 有 $(($total_reqs - $reqs_in_solution)) 个需求文档未在方案设计中关联"
    fi

    write_report ""

    # 2. 检查未关联的需求文档
    write_report "2. 未关联的需求文档"
    write_report "--------------------------------"
    
    if [ "$total_reqs" -gt "$reqs_in_solution" ]; then
        while IFS= read -r req_file; do
            req_id=$(basename "$req_file" .md)
            
            if [ -f "$SOLUTION_DIR/solution-map.json" ]; then
                if ! jq -e --arg req_id "$req_id" '.req_module_map | has($req_id)' "$SOLUTION_DIR/solution-map.json" >/dev/null; then
                    write_report "   - 需求未关联: $req_id"
                fi
            fi
        done < <(find "$REQUIREMENTS_DIR" -name "*.md" | sort)
    else
        write_report "   所有需求文档均已关联到方案设计中"
    fi

    write_report ""

    # 3. 检查模块与需求的关联是否符合预期
    write_report "3. 模块与需求关联检查"
    write_report "--------------------------------"
    
    if [ -d "$SOLUTION_DIR/modules" ]; then
        while IFS= read -r module_dir; do
            module_name=$(basename "$module_dir")
            
            if [ "$module_name" != "_example" ] && [ -f "$module_dir/reqs.json" ]; then
                local module_reqs=$(jq -r '.reqs | length' "$module_dir/reqs.json")
                write_report "   模块 $module_name 关联需求数量: $module_reqs"
                
                if [ "$module_reqs" -eq 0 ]; then
                    write_report "⚠️  警告: 模块 $module_name 未关联任何需求"
                fi
            fi
        done < <(find "$SOLUTION_DIR/modules" -type d -not -name "_example" -not -path "*/.git*" | sort)
    fi

    write_report ""

    # 4. 检查 API 设计与需求的关联是否符合预期
    write_report "4. API 设计与需求关联检查"
    write_report "--------------------------------"
    
    if [ -d "$SOLUTION_DIR/modules" ]; then
        while IFS= read -r module_dir; do
            module_name=$(basename "$module_dir")
            
            if [ "$module_name" != "_example" ] && [ -f "$module_dir/apis.json" ]; then
                local module_apis=$(jq -r '.apis | length' "$module_dir/apis.json")
                
                if [ "$module_apis" -gt 0 ]; then
                    write_report "   模块 $module_name API 数量: $module_apis"
                fi
            fi
        done < <(find "$SOLUTION_DIR/modules" -type d -not -name "_example" -not -path "*/.git*" | sort)
    fi

    write_report ""

    # 5. 检查是否有新增的需求文档未在方案设计中体现
    write_report "5. 新增需求文档检查"
    write_report "--------------------------------"
    
    if [ -f "$SOLUTION_DIR/meta/version.json" ]; then
        local last_checked=$(jq -r '.last_checked_reqs' "$SOLUTION_DIR/meta/version.json")
        
        if [ "$last_checked" != "null" ]; then
            while IFS= read -r req_file; do
                local req_date=$(stat -c %y "$req_file" | cut -d. -f1)
                
                if [ "$req_date" > "$last_checked" ]; then
                    req_id=$(basename "$req_file" .md)
                    write_report "⚠️  警告: 需求文档 $req_id 可能需要关联到方案设计中"
                fi
            done < <(find "$REQUIREMENTS_DIR" -name "*.md" | sort)
        fi
    fi

    write_report ""

    # 6. 检查是否有需求文档被删除但在方案设计中仍然存在
    write_report "6. 删除需求文档检查"
    write_report "--------------------------------"
    
    if [ -f "$SOLUTION_DIR/solution-map.json" ]; then
        while read -r req_id; do
            if [ ! -f "$REQUIREMENTS_DIR/$req_id.md" ]; then
                write_report "⚠️  警告: 需求 $req_id 在方案设计中存在但需求文档已删除"
            fi
        done < <(jq -r '.req_module_map | keys[]' "$SOLUTION_DIR/solution-map.json" 2>/dev/null)
    fi
}

# 执行检查
echo "正在检查需求变更与方案设计的差异..."
check_requirements_solution_diff

# 7. 检查是否需要更新 last_checked_reqs
if [ -f "$SOLUTION_DIR/meta/version.json" ]; then
    local current_date=$(date '+%Y-%m-%d %H:%M:%S')
    if ! $DRY_RUN; then
        jq --arg date "$current_date" '.last_checked_reqs = $date' "$SOLUTION_DIR/meta/version.json" > "$TEMP_FILE" && mv "$TEMP_FILE" "$SOLUTION_DIR/meta/version.json"
    fi
fi

# 输出最终报告
if ! $DRY_RUN; then
    mv "$TEMP_REPORT" "$REPORT_FILE"
    echo "✅ 差异报告已生成: $REPORT_FILE"
fi

exit 0
