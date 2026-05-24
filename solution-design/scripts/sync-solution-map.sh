#!/bin/bash
# sync-solution-map.sh - 同步方案设计与需求的映射关系
#
# 用法：
#   bash sync-solution-map.sh <project> [--dry-run]
#   例：bash sync-solution-map.sh smart-college
#   例：bash sync-solution-map.sh smart-college --dry-run
#
# 行为：
#   1. 读取项目的需求文件
#   2. 读取项目的方案设计文件
#   3. 建立需求与模块的映射关系
#   4. 建立需求与 API 的映射关系
#   5. 建立 API 与代码的映射关系（如果有代码库）
#   6. 输出映射关系到 solution-map.json 文件

set -euo pipefail

SKILL_DIR="$(cd "$(dirname "$0")/.." && pwd)"
WORKSPACE_DIR="$(cd "$SKILL_DIR/../.." && pwd)"

DRY_RUN=false

# 参数处理
if [ $# -lt 1 ]; then
    echo "❌ 用法: bash sync-solution-map.sh <project> [--dry-run]"
    echo "   例: bash sync-solution-map.sh smart-college"
    echo "   例: bash sync-solution-map.sh smart-college --dry-run"
    exit 1
fi

PROJECT="$1"

if [ "$#" -ge 2 ] && [ "$2" == "--dry-run" ]; then
    DRY_RUN=true
    echo "🔍 执行 dry run 模式，不会实际更新 solution-map.json"
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

# 检查是否有代码库
CODE_DIR="$WORKSPACE_DIR/projects/$PROJECT/src"
HAS_CODE=false
if [ -d "$CODE_DIR" ]; then
    HAS_CODE=true
fi

# 创建解决方案映射
SOLUTION_MAP="$(mktemp /tmp/solution-map.XXXXXXXXXX)"
cat > "$SOLUTION_MAP" <<EOF
{
  "project": "$PROJECT",
  "generated_at": "$(date -u +"%Y-%m-%dT%H:%M:%SZ")",
  "version": "v2.0",
  "modules": [],
  "req_module_map": {},
  "req_api_map": {},
  "api_code_map": {}
}
EOF

# 读取所有模块信息
MODULES_DIR="$SOLUTION_DIR/modules"
for MODULE in "$MODULES_DIR"/*; do
    if [ -d "$MODULE" ] && [ "$(basename "$MODULE")" != "_example" ]; then
        MODULE_NAME="$(basename "$MODULE")"
        MODULE_DESC=""
        if [ -f "$MODULE/design.md" ]; then
            MODULE_DESC="$(head -20 "$MODULE/design.md" | grep -E '^(##|###)' | head -1 | sed 's/^##* //')"
        fi
        
        # 读取 reqs.json
        MODULE_REQS=[]
        if [ -f "$MODULE/reqs.json" ]; then
            MODULE_REQS="$(cat "$MODULE/reqs.json")"
        fi
        
        # 读取 apis.json
        MODULE_APIS=[]
        if [ -f "$MODULE/apis.json" ]; then
            MODULE_APIS="$(cat "$MODULE/apis.json")"
        fi
        
        # 添加模块信息
        jq --arg name "$MODULE_NAME" \
           --arg desc "$MODULE_DESC" \
           --argjson reqs "$MODULE_REQS" \
           --argjson apis "$MODULE_APIS" \
           '.modules += [{"name": $name, "description": $desc, "reqs": $reqs, "apis": $apis}]' \
           "$SOLUTION_MAP" > "$SOLUTION_MAP.tmp" && mv "$SOLUTION_MAP.tmp" "$SOLUTION_MAP"
    fi
done

# 建立需求与模块的映射关系
for MODULE in "$SOLUTION_DIR/modules"/*; do
    if [ -d "$MODULE" ] && [ "$(basename "$MODULE")" != "_example" ]; then
        MODULE_NAME="$(basename "$MODULE")"
        if [ -f "$MODULE/reqs.json" ]; then
            # 使用 jq 正确解析 reqs.json
            MODULE_REQS="$(jq -r '.reqs[]?.id // .[]?.id // .[]' "$MODULE/reqs.json" 2>/dev/null || echo '')"
            for REQ_ID in $MODULE_REQS; do
                # 检查是否是有效的 REQ-XXXXXX-XXXX 格式
                if [[ "$REQ_ID" =~ REQ-[0-9]{8}-[0-9]{3} ]]; then
                    # 建立 req -> module 映射
                    jq --arg req "$REQ_ID" \
                       --arg mod "$MODULE_NAME" \
                       '.req_module_map |= . + { ($req): ($mod) }' \
                       "$SOLUTION_MAP" > "$SOLUTION_MAP.tmp" && mv "$SOLUTION_MAP.tmp" "$SOLUTION_MAP"
                
                    # 建立 req -> apis 映射（如果该模块有 apis.json）
                    if [ -f "$MODULE/apis.json" ]; then
                        MODULE_APIS="$(jq -c '.apis' "$MODULE/apis.json")"
                        jq --arg req "$REQ_ID" \
                           --argjson apis "$MODULE_APIS" \
                           '.req_api_map |= . + { ($req): ($apis) }' \
                           "$SOLUTION_MAP" > "$SOLUTION_MAP.tmp" && mv "$SOLUTION_MAP.tmp" "$SOLUTION_MAP"
                    fi
                fi
            done
        fi
    fi
done

# 建立 API 与代码的映射关系（如果有代码库）
if $HAS_CODE; then
    echo "建立 API 与代码的映射关系..."
    
    # 遍历所有 API 并查找对应的代码文件
    while IFS= read -r MODULE; do
        if [ -d "$MODULE" ] && [ "$(basename "$MODULE")" != "_example" ]; then
            MODULE_NAME="$(basename "$MODULE")"
            
            if [ -f "$MODULE/apis.json" ]; then
                while read -r api_name; do
                    if [ -n "$api_name" ]; then
                        # 尝试在代码库中找到与 API 相关的文件
                        # 简单的匹配逻辑：查找包含 API 名称或相关关键词的文件
                        CODE_FILES=$(grep -rl "$api_name" "$CODE_DIR" --include="*.ts" --include="*.tsx" --include="*.js" --include="*.jsx" 2>/dev/null)
                        
                        if [ -n "$CODE_FILES" ]; then
                            # 建立 api -> code 映射
                            for CODE_FILE in $CODE_FILES; do
                                # 去掉前缀路径，只保留相对于项目代码根目录的路径
                                RELATIVE_PATH=$(echo "$CODE_FILE" | sed "s|$CODE_DIR/||")
                                
                                jq --arg api "$api_name" \
                                   --arg file "$RELATIVE_PATH" \
                                   '.api_code_map |= if has($api) then .[$api] += [$file] | map_values(unique) else . + { ($api): [$file] } end' \
                                   "$SOLUTION_MAP" > "$SOLUTION_MAP.tmp" && mv "$SOLUTION_MAP.tmp" "$SOLUTION_MAP"
                            done
                        fi
                    fi
                done < <(jq -r '.apis[].name' "$MODULE/apis.json" 2>/dev/null)
            fi
        fi
    done < <(ls -1 "$SOLUTION_DIR/modules")
fi

# 输出映射文件到项目目录
OUTPUT_FILE="$SOLUTION_DIR/solution-map.json"
if $DRY_RUN; then
    echo -e "\n🔍 Dry run 完成，以下是将生成的 solution-map.json 的内容预览:"
    head -50 "$SOLUTION_MAP"
    if [ $(wc -l < "$SOLUTION_MAP") -gt 50 ]; then
        echo "..."
        echo "文件过长，未显示全部内容"
    fi
    echo -e "\n✅ 预览完成，请使用不带 --dry-run 参数的命令实际生成文件"
else
    cp "$SOLUTION_MAP" "$OUTPUT_FILE"
    echo "✅ 解决方案映射文件已生成: $OUTPUT_FILE"

    # 输出映射关系概览
    echo "--- 映射关系概览 ---"
    echo "模块数量: $(jq -r '.modules | length' "$OUTPUT_FILE")"
    echo "需求数量: $(jq -r '.req_module_map | length' "$OUTPUT_FILE")"
    echo "API 数量: $(jq -r '.modules | map(.apis | length) | add' "$OUTPUT_FILE")"
    if $HAS_CODE; then
        echo "API-代码映射数量: $(jq -r '.api_code_map | length' "$OUTPUT_FILE")"
    fi
fi

# 清理临时文件
rm "$SOLUTION_MAP"

exit 0
