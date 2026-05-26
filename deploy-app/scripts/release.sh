#!/bin/bash
# release.sh - 版本发布脚本（四联动机制的入口）
# 用法:
#   release.sh <app_id> --bump major|minor|patch
#   release.sh <app_id> --explicit v1.2.3
#   release.sh <app_id> --bump patch --dry-run
#
# 行为:
#   1. 从 _registry.json 找到项目代码目录
#   2. 定位 package.json（优先 apps/web，再 packages/web，再根目录）
#   3. 读上一个 tag（git tag --sort=-creatordate | head -1），无则 v0.0.0
#   4. 算新版本号
#   5. 改 package.json.version（不带 v）
#   6. 追加 CHANGELOG.md
#   7. git add + commit + tag + push

set -euo pipefail

C_R='\033[0;31m'; C_G='\033[0;32m'; C_Y='\033[1;33m'; C_B='\033[0;36m'; C_N='\033[0m'
log()     { printf "${C_B}▶ %s${C_N}\n" "$*"; }
log_ok()  { printf "${C_G}✓ %s${C_N}\n" "$*"; }
log_warn(){ printf "${C_Y}⚠ %s${C_N}\n" "$*"; }
log_err() { printf "${C_R}✗ %s${C_N}\n" "$*" >&2; }
die()     { log_err "$*"; exit 1; }

WS_ROOT="/var/lib/openclaw/.openclaw/workspace"
REGISTRY="$WS_ROOT/knowledge-repos/projects/_registry.json"

usage() {
    cat <<USAGE
Usage:
  $(basename "$0") <app_id> --bump major|minor|patch [--dry-run]
  $(basename "$0") <app_id> --explicit vX.Y.Z [--dry-run]

参见: knowledge-repos/management/PRINCIPLES/VERSIONING.md
USAGE
    exit 1
}

APP_ID="${1:-}"; [ -z "$APP_ID" ] && usage
shift

BUMP=""; EXPLICIT=""; DRY_RUN="false"
while [ $# -gt 0 ]; do
    case "$1" in
        --bump)     BUMP="$2"; shift 2 ;;
        --explicit) EXPLICIT="$2"; shift 2 ;;
        --dry-run)  DRY_RUN="true"; shift ;;
        -h|--help)  usage ;;
        *)          die "未知参数: $1" ;;
    esac
done

[ -z "$BUMP" ] && [ -z "$EXPLICIT" ] && die "必须指定 --bump 或 --explicit"
[ -n "$BUMP" ] && [ -n "$EXPLICIT" ] && die "--bump 和 --explicit 互斥"

# 1. 校验注册
[ -f "$REGISTRY" ] || die "_registry.json 不存在"
PROJ_EXISTS="$(jq -r --arg k "$APP_ID" '.projects[$k].code // empty' "$REGISTRY")"
[ -n "$PROJ_EXISTS" ] || die "项目 '$APP_ID' 未在 _registry.json 注册"

# 2. 定位代码目录（与 deploy-app 的查找策略一致）
APPS_JSON="$WS_ROOT/skills/deploy-app/config/apps.json"
CODE_DIR=""
if [ -f "$APPS_JSON" ]; then
    CODE_DIR="$(jq -r --arg k "$APP_ID" '.apps[$k].project_code_path // .apps[$k].project_path // empty' "$APPS_JSON")"
fi
# 默认猜 code-repos/<app>
[ -z "$CODE_DIR" ] && CODE_DIR="$WS_ROOT/code-repos/$APP_ID"
[ -d "$CODE_DIR" ] || die "代码目录不存在: $CODE_DIR"

# 找 git root（顺着 CODE_DIR 向上找）
GIT_ROOT="$(cd "$CODE_DIR" && git rev-parse --show-toplevel 2>/dev/null || true)"
[ -z "$GIT_ROOT" ] && die "$CODE_DIR 不是 git 仓库"
log_ok "git root: $GIT_ROOT"

# 找 package.json（优先 apps/web → packages/web → 根）
PKG=""
for cand in "$CODE_DIR/package.json" "$GIT_ROOT/apps/web/package.json" "$GIT_ROOT/packages/web/package.json" "$GIT_ROOT/package.json"; do
    if [ -f "$cand" ]; then PKG="$cand"; break; fi
done
[ -z "$PKG" ] && die "未找到 package.json"
log_ok "package.json: $PKG"

# 3. 读上一 tag
cd "$GIT_ROOT"
LAST_TAG="$(git tag --sort=-creatordate 2>/dev/null | grep -E '^v[0-9]+\.[0-9]+\.[0-9]+' | head -1 || true)"
[ -z "$LAST_TAG" ] && LAST_TAG="v0.0.0"
log "上一个 tag: $LAST_TAG"

# 4. 算新版本号
if [ -n "$EXPLICIT" ]; then
    echo "$EXPLICIT" | grep -qE '^v[0-9]+\.[0-9]+\.[0-9]+$' || die "--explicit 必须形如 vX.Y.Z"
    NEW_TAG="$EXPLICIT"
else
    case "$BUMP" in major|minor|patch) ;; *) die "--bump 必须是 major|minor|patch" ;; esac
    BARE="${LAST_TAG#v}"
    IFS='.' read -r MA MI PA <<<"$BARE"
    case "$BUMP" in
        major) MA=$((MA+1)); MI=0; PA=0 ;;
        minor) MI=$((MI+1)); PA=0 ;;
        patch) PA=$((PA+1)) ;;
    esac
    NEW_TAG="v${MA}.${MI}.${PA}"
fi
NEW_VER="${NEW_TAG#v}"
log_ok "新版本号: $NEW_TAG (package.json.version = $NEW_VER)"

if [ "$DRY_RUN" = "true" ]; then
    log_warn "dry-run: 仅展示，不写不 commit"
    echo
    echo "将要做的事："
    echo "  1) 写 $PKG 的 .version = $NEW_VER"
    echo "  2) 追加 CHANGELOG.md 段落"
    echo "  3) git add -A && git commit -m 'release: $NEW_TAG'"
    echo "  4) git tag $NEW_TAG"
    echo "  5) git push origin HEAD --tags"
    echo
    log "自上次 tag 到 HEAD 的提交:"
    if [ "$LAST_TAG" = "v0.0.0" ]; then
        git log --oneline -n 20 || true
    else
        git log --oneline "${LAST_TAG}..HEAD" || true
    fi
    exit 0
fi

# 5. 写 package.json.version
TMP_PKG="$(mktemp)"
jq --arg v "$NEW_VER" '.version = $v' "$PKG" > "$TMP_PKG" && mv "$TMP_PKG" "$PKG"
log_ok "package.json.version 已更新为 $NEW_VER"

# 6. 追加 CHANGELOG.md
CHANGELOG="$GIT_ROOT/CHANGELOG.md"
TODAY="$(date '+%F')"
TMP_CL="$(mktemp)"
{
    echo "# CHANGELOG"
    echo ""
    echo "## $NEW_TAG — $TODAY"
    echo ""
    if [ "$LAST_TAG" = "v0.0.0" ]; then
        git log --oneline -n 20 | sed 's/^/- /'
    else
        git log --oneline "${LAST_TAG}..HEAD" | sed 's/^/- /'
    fi
    echo ""
    if [ -f "$CHANGELOG" ]; then
        # 去掉旧文件第一行的 "# CHANGELOG"，把剩余拼接上来
        tail -n +2 "$CHANGELOG"
    fi
} > "$TMP_CL"
mv "$TMP_CL" "$CHANGELOG"
log_ok "CHANGELOG.md 已追加 $NEW_TAG 段"

# 7. git commit + tag + push
git add -A
if git diff --cached --quiet; then
    log_warn "无变更可提交，跳过 commit"
else
    git commit -m "release: $NEW_TAG"
    log_ok "已 commit: release: $NEW_TAG"
fi
git tag -a "$NEW_TAG" -m "release $NEW_TAG"
log_ok "已打 tag: $NEW_TAG"

if git remote get-url origin >/dev/null 2>&1; then
    log "推送到 origin..."
    if git push origin HEAD; then log_ok "main 已推"; else log_warn "main 推送失败（请手动重试）"; fi
    if git push origin "$NEW_TAG"; then log_ok "tag 已推"; else log_warn "tag 推送失败（请手动重试）"; fi
else
    log_warn "无 origin remote，跳过 push"
fi

echo
log_ok "🎉 发布完成: $NEW_TAG"
echo
echo "下一步:"
echo "  bash $WS_ROOT/skills/deploy-app/scripts/deploy.sh prod $APP_ID --version $NEW_TAG --approved-by <user>"
