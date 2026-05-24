#!/bin/bash
# validate-solution.sh - 方案设计完整性检查
#
# 用法：
#   bash validate-solution.sh <project> [--detailed]
#   例：bash validate-solution.sh smart-college
#   例：bash validate-solution.sh smart-college --detailed
#
# 行为：
#   1. 检查方案设计目录结构的完整性
#   2. 验证关键文件的存在性和格式
#   3. 检查方案文档的完整性
#   4. 验证需求与模块的关联关系
#   5. 检查 API 设计的完整性
#   6. 验证架构和数据库设计的完整性

set -euo pipefail

SKILL_DIR="$(cd "$(dirname "$0")/.." && pwd)"
WORKSPACE_DIR="$(cd "$SKILL_DIR/../.." && pwd)"

DETAILED=false

# 参数处理
if [ $# -lt 1 ]; then
    echo "❌ 用法: bash validate-solution.sh <project> [--detailed]"
    echo "   例: bash validate-solution.sh smart-college"
    echo "   例: bash validate-solution.sh smart-college --detailed"
    exit 1
fi

PROJECT="$1"

if [ "$#" -ge 2 ] && [ "$2" == "--detailed" ]; then
    DETAILED=true
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

# 检查结果变量
PASS=0
FAIL=0
WARN=0
DETAILED_REPORT=""

# 辅助函数：记录检查结果
record_result() {
    local level="$1"
    local message="$2"
    local file=""
    
    if [ "$#" -ge 3 ]; then
        file="$3"
    fi
    
    case "$level" in
        "PASS")
            ((PASS++))
            if $DETAILED; then
                DETAILED_REPORT+="✅ PASS: $message"
                if [ -n "$file" ]; then
                    DETAILED_REPORT+=" ($file)"
                fi
                DETAILED_REPORT+="\n"
            fi
            ;;
        "WARN")
            ((WARN++))
            DETAILED_REPORT+="⚠️  WARN: $message"
            if [ -n "$file" ]; then
                DETAILED_REPORT+=" ($file)"
            fi
            DETAILED_REPORT+="\n"
            ;;
        "FAIL")
            ((FAIL++))
            DETAILED_REPORT+="❌ FAIL: $message"
            if [ -n "$file" ]; then
                DETAILED_REPORT+=" ($file)"
            fi
            DETAILED_REPORT+="\n"
            ;;
    esac
}

# 1. 检查方案设计目录结构
echo "1. 检查方案设计目录结构..."
for dir in "architecture" "database" "api" "modules" "adr" "meta"; do
    if [ -d "$SOLUTION_DIR/$dir" ]; then
        record_result "PASS" "$dir 目录存在"
    else
        record_result "FAIL" "$dir 目录不存在"
    fi
done

# 2. 检查架构设计文件
echo "2. 检查架构设计文件..."
if [ -f "$SOLUTION_DIR/architecture/overview.md" ]; then
    record_result "PASS" "架构设计文档存在" "$SOLUTION_DIR/architecture/overview.md"
else
    record_result "FAIL" "架构设计文档不存在" "$SOLUTION_DIR/architecture/overview.md"
fi

# 3. 检查数据库设计文件
echo "3. 检查数据库设计文件..."
if [ -f "$SOLUTION_DIR/database/schema.md" ]; then
    record_result "PASS" "数据库设计文档存在" "$SOLUTION_DIR/database/schema.md"
else
    record_result "FAIL" "数据库设计文档不存在" "$SOLUTION_DIR/database/schema.md"
fi

# 4. 检查 API 设计文件
echo "4. 检查 API 设计文件..."
if [ -f "$SOLUTION_DIR/api/api-design.md" ]; then
    record_result "PASS" "API 设计文档存在" "$SOLUTION_DIR/api/api-design.md"
else
    record_result "FAIL" "API 设计文档不存在" "$SOLUTION_DIR/api/api-design.md"
fi

# 5. 检查模块设计文件
echo "5. 检查模块设计文件..."
MODULES_DIR="$SOLUTION_DIR/modules"
if [ -d "$MODULES_DIR" ]; then
    for MODULE in "$MODULES_DIR"/*; do
        if [ -d "$MODULE" ] && [ "$(basename "$MODULE")" != "_example" ]; then
            MODULE_NAME="$(basename "$MODULE")"
            
            if [ -f "$MODULE/design.md" ]; then
                record_result "PASS" "模块设计文档存在" "$MODULE/design.md"
            else
                record_result "WARN" "模块设计文档不存在" "$MODULE/design.md"
            fi
            
            if [ -f "$MODULE/reqs.json" ]; then
                record_result "PASS" "模块需求关联文件存在" "$MODULE/reqs.json"
            else
                record_result "WARN" "模块需求关联文件不存在" "$MODULE/reqs.json"
            fi
            
            if [ -f "$MODULE/apis.json" ]; then
                record_result "PASS" "模块 API 设计文件存在" "$MODULE/apis.json"
            else
                record_result "WARN" "模块 API 设计文件不存在" "$MODULE/apis.json"
            fi
        fi
    done
else
    record_result "FAIL" "模块目录不存在" "$MODULES_DIR"
fi

# 6. 检查 ADR 决策记录
echo "6. 检查 ADR 决策记录..."
ADR_DIR="$SOLUTION_DIR/adr"
if [ -d "$ADR_DIR" ]; then
    ADR_FILES=("$ADR_DIR"/ADR-*.md)
    if [ "${#ADR_FILES[@]}" -gt 0 ] && [ -f "${ADR_FILES[0]}" ]; then
        record_result "PASS" "找到 $(ls -1 "$ADR_DIR"/*.md 2>/dev/null | wc -l) 个 ADR 文件"
    else
        record_result "WARN" "未找到 ADR 文件"
    fi
else
    record_result "FAIL" "ADR 目录不存在" "$ADR_DIR"
fi

# 7. 检查项目配置文件
echo "7. 检查项目配置文件..."
if [ -f "$SOLUTION_DIR/meta/version.json" ]; then
    record_result "PASS" "项目配置文件存在" "$SOLUTION_DIR/meta/version.json"
else
    record_result "WARN" "项目配置文件不存在" "$SOLUTION_DIR/meta/version.json"
fi

# 8. 检查解决方案映射文件
echo "8. 检查解决方案映射文件..."
if [ -f "$SOLUTION_DIR/solution-map.json" ]; then
    record_result "PASS" "解决方案映射文件存在" "$SOLUTION_DIR/solution-map.json"
    
    # 验证文件格式是否正确
    if jq . "$SOLUTION_DIR/solution-map.json" > /dev/null 2>&1; then
        record_result "PASS" "解决方案映射文件格式正确"
    else
        record_result "FAIL" "解决方案映射文件格式错误" "$SOLUTION_DIR/solution-map.json"
    fi
else
    record_result "WARN" "解决方案映射文件不存在" "$SOLUTION_DIR/solution-map.json"
fi

# 输出总结
echo -e "\n--- 方案设计完整性检查报告 ---"
echo "✅ 通过: $PASS"
echo "⚠️  警告: $WARN"
echo "❌ 失败: $FAIL"

# 输出详细报告（如果需要）
if [ $FAIL -gt 0 ] || [ $WARN -gt 0 ] || $DETAILED; then
    echo -e "\n--- 详细报告 ---"
    echo -e "$DETAILED_REPORT"
fi

# 根据检查结果返回相应的退出码
if [ $FAIL -gt 0 ]; then
    exit 2
elif [ $WARN -gt 0 ]; then
    exit 1
else
    exit 0
fi
