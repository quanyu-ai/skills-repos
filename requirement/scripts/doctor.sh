#!/bin/bash
# doctor.sh - requirement skill 自检脚本
# 输出最后一行 READY 或 NEED_SETUP: <原因>

set -e

SKILL_DIR="$(cd "$(dirname "$0")/.." && pwd)"
WORKSPACE_ROOT="$(cd "$SKILL_DIR/../.." && pwd)"
DOCS_ROOT="$WORKSPACE_ROOT/docs-repos"

fail() {
    echo "NEED_SETUP: $1"
    exit 1
}

# 检查 jq
command -v jq >/dev/null 2>&1 || fail "jq not installed - run: sudo yum install -y jq"

# 检查 pandoc
command -v pandoc >/dev/null 2>&1 || fail "pandoc not installed - run: sudo yum install -y pandoc"

# 检查 python3
command -v python3 >/dev/null 2>&1 || fail "python3 not installed"

# 检查 templates 存在
[ -f "$SKILL_DIR/templates/req-template.md" ] || fail "templates/req-template.md missing"
[ -f "$SKILL_DIR/templates/requirements-map.template.json" ] || fail "templates/requirements-map.template.json missing"

# 检查 docs-repos 根目录
[ -d "$DOCS_ROOT" ] || echo "WARN: docs-repos not found at $DOCS_ROOT - 项目目录需要手动创建"

# ─────────────────────────────────────────
# 一致性扫描：遍历所有项目的 requirements/
# ─────────────────────────────────────────
VALID_STATUSES="draft reviewing approved implementing done deprecated"

is_valid_status() {
    local s="$1"
    for v in $VALID_STATUSES; do [ "$v" = "$s" ] && return 0; done
    return 1
}

get_fm_field() {
    awk -v k="$2" '
        BEGIN { in_fm=0 }
        /^---$/ { if (in_fm) exit; in_fm=1; next }
        in_fm && $0 ~ "^"k":[[:space:]]" {
            sub("^"k":[[:space:]]*", "")
            gsub(/^"|"$/, "")
            print; exit
        }
    ' "$1"
}

CONSISTENCY_FAILED=0

if [ -d "$DOCS_ROOT" ]; then
    while IFS= read -r req_dir; do
        [ -d "$req_dir" ] || continue
        project=$(basename "$(dirname "$req_dir")")
        map="$req_dir/requirements-map.json"

        shopt -s nullglob
        for f in "$req_dir"/REQ-*.md; do
            id=$(basename "$f" .md)

            # 跳过无 frontmatter 的 legacy 文件（首行不是 ---）
            first_line=$(head -n1 "$f")
            if [ "$first_line" != "---" ]; then
                continue
            fi

            status=$(get_fm_field "$f" "status")

            # 1. status 在合法集合内
            if [ -z "$status" ]; then
                echo "  ✗ [$project] $id: status 字段缺失"
                CONSISTENCY_FAILED=1
                continue
            fi
            if ! is_valid_status "$status"; then
                echo "  ✗ [$project] $id: 非法 status '$status'（合法: $VALID_STATUSES）"
                CONSISTENCY_FAILED=1
            fi

            # 2. history 格式（如果存在）：必须以 'history:' 开头，下面是
            #    '  - { ... }' （inline 风格）或 '- key: val' / '  - key: val' （block 风格）
            #    禁止顶级 list 项之外的非缩进非法行
            if grep -q '^history:' "$f"; then
                bad=$(awk '
                    BEGIN { in_fm=0; in_h=0 }
                    /^---$/ { if (in_fm) exit; in_fm=1; next }
                    in_fm && /^history:[[:space:]]*$/ { in_h=1; next }
                    in_fm && in_h {
                        # 遇到下一个顶级字段则退出 history 区
                        if ($0 ~ /^[a-zA-Z_][a-zA-Z0-9_]*:/) { in_h=0; next }
                        # 空行允许
                        if (NF==0) next
                        # 合法：以 - 开头（任意缩进），或以空格开头的延续字段
                        if ($0 ~ /^[[:space:]]*-[[:space:]]/) next
                        if ($0 ~ /^[[:space:]]+[a-zA-Z_]/) next
                        print NR":"$0; exit
                    }
                ' "$f")
                if [ -n "$bad" ]; then
                    echo "  ✗ [$project] $id: history 格式不合规 ($bad)"
                    CONSISTENCY_FAILED=1
                fi
            fi

            # 3. 与 map 一致
            if [ -f "$map" ]; then
                map_status=$(jq -r --arg id "$id" '.requirements[$id].status // "MISSING"' "$map")
                if [ "$map_status" = "MISSING" ]; then
                    echo "  ✗ [$project] $id: 不在 requirements-map.json 中（请跑 sync-map.sh）"
                    CONSISTENCY_FAILED=1
                elif [ "$map_status" != "$status" ]; then
                    echo "  ✗ [$project] $id: frontmatter status=$status，map=$map_status（请跑 sync-map.sh）"
                    CONSISTENCY_FAILED=1
                fi
            fi
        done
        shopt -u nullglob
    done < <(find "$DOCS_ROOT" -mindepth 2 -maxdepth 2 -type d -name requirements)
fi

if [ $CONSISTENCY_FAILED -ne 0 ]; then
    echo "NEED_SETUP: 一致性检查失败，见上方明细"
    exit 1
fi

echo "READY"
exit 0
