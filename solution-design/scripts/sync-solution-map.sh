#!/bin/bash
# sync-solution-map.sh - 同步方案设计与需求的映射关系
#
# 用法：
#   bash sync-solution-map.sh <project>
#   例：bash sync-solution-map.sh smart-college
#
# 行为：
#   1. 读取项目的需求文件
#   2. 读取项目的方案设计文件
#   3. 建立需求与模块的映射关系
#   4. 建立需求与 API 的映射关系
#   5. 输出映射关系到 solution-map.json 文件

set -euo pipefail

SKILL_DIR="$(cd "$(dirname "$0")/.." && pwd)"
WORKSPACE_DIR="$(cd "$SKILL_DIR/../.." && pwd)"

# 参数校验
if [ $# -lt 1 ]; then
    echo "❌ 用法: bash sync-solution-map.sh <project>"
    echo "   例: bash sync-solution-map.sh smart-college"
    exit 1
fi

PROJECT="$1"
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

# 创建解决方案映射
SOLUTION_MAP="$(mktemp /tmp/solution-map.XXXXXXXXXX)"
cat > "$SOLUTION_MAP" <<EOF
{
  "project": "$PROJECT",
  "generated_at": "$(date -u +"%Y-%m-%dT%H:%M:%SZ")",
  "version": "v1.0",
  "modules": [],
  "req_module_map": {},
  "req_api_map": {}
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

# 输出映射文件到项目目录
OUTPUT_FILE="$SOLUTION_DIR/solution-map.json"
cp "$SOLUTION_MAP" "$OUTPUT_FILE"
echo "✅ 解决方案映射文件已生成: $OUTPUT_FILE"

# 输出映射关系概览
echo "--- 映射关系概览 ---"
echo "模块数量: $(jq -r '.modules | length' "$OUTPUT_FILE")"
echo "需求数量: $(jq -r '.req_module_map | length' "$OUTPUT_FILE")"
echo "API 数量: $(jq -r '.modules | map(.apis | length) | add' "$OUTPUT_FILE")"

# 清理临时文件
rm "$SOLUTION_MAP"

exit 0
