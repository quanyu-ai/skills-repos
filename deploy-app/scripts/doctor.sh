#!/bin/bash
# doctor.sh - deploy-app skill 自检脚本
# 用法:
#   doctor.sh                  常规自检（输出 READY 或 NEED_SETUP）
#   doctor.sh --check-apps     全量预扫描所有 app × env 的路径合法性（矩阵表）
# 退出码：0 = READY / 全部 OK, 1 = NEED_SETUP / 发现路径错误

set -e

SKILL_DIR="$(cd "$(dirname "$0")/.." && pwd)"
CONFIG_DIR="$SKILL_DIR/config"
APPS_JSON="$CONFIG_DIR/apps.json"
ENVS_JSON="$CONFIG_DIR/environments.json"
fail() {
    echo "NEED_SETUP: $1"
    exit 1
}

# 前置：jq 必装（否则后面的 JSON 校验跑不动）
command -v jq >/dev/null 2>&1 || fail "jq not installed - run: sudo apt-get install -y jq"

# ============================================================
# --check-apps: 全量预扫描所有 app × env 的路径合法性
# ============================================================
if [ "${1:-}" = "--check-apps" ]; then
    [ -f "$APPS_JSON" ] || fail "apps.json missing"
    jq empty "$APPS_JSON" 2>/dev/null || fail "apps.json invalid JSON"

    ENVS_LIST=(proto test demo prod)

    # 计算 app 名最大宽度，做粗略对齐
    MAX_NAME=10
    while IFS= read -r app_key; do
        L=${#app_key}
        [ "$L" -gt "$MAX_NAME" ] && MAX_NAME=$L
    done < <(jq -r '.apps | keys[]' "$APPS_JSON")

    # 表头
    printf "%-${MAX_NAME}s" "应用"
    for e in "${ENVS_LIST[@]}"; do
        printf "  %-22s" "$e"
    done
    printf "\n"
    printf '%.0s-' $(seq 1 $((MAX_NAME + 24 * ${#ENVS_LIST[@]}))); printf "\n"

    TOTAL_APPS=0
    TOTAL_ERRORS=0

    while IFS= read -r app_key; do
        TOTAL_APPS=$((TOTAL_APPS + 1))
        printf "%-${MAX_NAME}s" "$app_key"
        for e in "${ENVS_LIST[@]}"; do
            # env_config.<e> 是否存在
            HAS_ENV=$(jq -r --arg k "$app_key" --arg e "$e" '.apps[$k].env_config | has($e)' "$APPS_JSON")
            if [ "$HAS_ENV" != "true" ]; then
                printf "  %-22s" "—(未配置)"
                continue
            fi

            # 取实际路径：优先 env_config.<e>.project_path
            ACT_PATH=$(jq -r --arg k "$app_key" --arg e "$e" '.apps[$k].env_config[$e].project_path // ""' "$APPS_JSON")
            # fallback：proto 用 project_proto_path，其它用 project_code_path
            if [ -z "$ACT_PATH" ] || [ "$ACT_PATH" = "null" ]; then
                if [ "$e" = "proto" ]; then
                    ACT_PATH=$(jq -r --arg k "$app_key" '.apps[$k].project_proto_path // ""' "$APPS_JSON")
                else
                    ACT_PATH=$(jq -r --arg k "$app_key" '.apps[$k].project_code_path // ""' "$APPS_JSON")
                fi
            fi

            if [ -z "$ACT_PATH" ] || [ "$ACT_PATH" = "null" ]; then
                printf "  %-22s" "❌(无路径)"
                TOTAL_ERRORS=$((TOTAL_ERRORS + 1))
            elif [ -d "$ACT_PATH" ]; then
                printf "  %-22s" "✅"
            else
                printf "  %-22s" "❌(路径不存在)"
                TOTAL_ERRORS=$((TOTAL_ERRORS + 1))
            fi
        done
        printf "\n"
    done < <(jq -r '.apps | keys[]' "$APPS_JSON")

    echo
    echo "扫描完成，共 $TOTAL_APPS 个应用，发现 $TOTAL_ERRORS 个路径错误"
    if [ "$TOTAL_ERRORS" -gt 0 ]; then
        exit 1
    fi
    exit 0
fi

# 检查项 1：apps.json 存在
[ -f "$CONFIG_DIR/apps.json" ] || fail "apps.json missing - run setup.md step 2"

# 检查项 2：environments.json 存在
[ -f "$CONFIG_DIR/environments.json" ] || fail "environments.json missing - run setup.md step 2"

# 检查项 3：apps.json JSON 格式有效
jq empty "$CONFIG_DIR/apps.json" 2>/dev/null || fail "apps.json invalid JSON"

# 检查项 4：environments.json JSON 格式有效
jq empty "$CONFIG_DIR/environments.json" 2>/dev/null || fail "environments.json invalid JSON"

# 检查项 5：本机 SSH 密钥（F-5：按环境条件检查，不强要求 deploy_local）
# 仅在 environments.json 里存在 ssh_key 为 deploy_local 的环境才检查
DEPLOY_LOCAL_NEEDED="false"
DEPLOY_PROD_NEEDED="false"
if jq -e '.environments | to_entries[] | select(.value.ssh_key | strings | contains("deploy_local"))' "$CONFIG_DIR/environments.json" >/dev/null 2>&1; then
    DEPLOY_LOCAL_NEEDED="true"
fi
if jq -e '.environments | to_entries[] | select(.value.ssh_key | strings | contains("deploy_prod"))' "$CONFIG_DIR/environments.json" >/dev/null 2>&1; then
    DEPLOY_PROD_NEEDED="true"
fi

if [ "$DEPLOY_LOCAL_NEEDED" = "true" ]; then
    [ -f "$HOME/.ssh/deploy_local" ] || fail "SSH deploy_local key missing - run setup.md step 5"
fi
if [ "$DEPLOY_PROD_NEEDED" = "true" ]; then
    if [ ! -f "$HOME/.ssh/deploy_prod" ]; then
        # 有 prod 环境但密钥不在 -> WARN 不 fail（远端部署由 init-remote-target.sh 引导）
        echo "WARN: SSH deploy_prod key missing - 远端部署需要，请生成后贴到腾讯云 deploy authorized_keys"
        echo "      或者跑: bash $SKILL_DIR/scripts/init-remote-target.sh root@<远端> --ssh-key ~/.ssh/<root密钥>"
    fi
fi

# 检查项 6：本机 SSH 联通（仅当 deploy_local 需要时）
if [ "$DEPLOY_LOCAL_NEEDED" = "true" ] && [ -f "$HOME/.ssh/deploy_local" ]; then
    ssh -i "$HOME/.ssh/deploy_local" \
        -o BatchMode=yes \
        -o ConnectTimeout=5 \
        -o StrictHostKeyChecking=no \
        deploy@localhost true 2>/dev/null \
        || fail "SSH localhost not configured - run setup.md step 5"
fi

# 检查项 7/8：OpenClaw skill env 注入（不阻塞，仅 WARN）
[ -n "$ALIYUN_HOST" ]  || echo "WARN: ALIYUN_HOST env not injected (set via skills.entries.deploy-app.env in ~/.openclaw/openclaw.json)"
[ -n "$TENCENT_HOST" ] || echo "WARN: TENCENT_HOST env not injected"

# 检查项 8: 僵尸部署锁检测 (>1小时算僵尸)
LOCK_DIR="/var/lib/openclaw/deploy-locks"
if [ -d "$LOCK_DIR" ]; then
    ZOMBIE_FOUND=""
    NOW_EPOCH=$(date +%s)
    for lockfile in "$LOCK_DIR"/*.lock; do
        [ -f "$lockfile" ] || continue
        LOCK_AGE=$(( NOW_EPOCH - $(stat -c %Y "$lockfile" 2>/dev/null || echo 0) ))
        if [ "$LOCK_AGE" -gt 3600 ]; then
            LOCK_PID=$(head -1 "$lockfile" 2>/dev/null || echo "unknown")
            APP_NAME=$(basename "$lockfile" .lock)
            # 检查 PID 是否还活着
            if [ "$LOCK_PID" != "unknown" ] && kill -0 "$LOCK_PID" 2>/dev/null; then
                echo "WARN: 部署锁僵尸 (但 PID $LOCK_PID 仍存活): $lockfile (age=${LOCK_AGE}s, app=$APP_NAME)"
            else
                echo "WARN: 部署锁僵尸 (PID 已死): $lockfile (age=${LOCK_AGE}s, app=$APP_NAME) -> 可安全删除"
            fi
            ZOMBIE_FOUND="yes"
        fi
    done
    [ -z "$ZOMBIE_FOUND" ] || echo "WARN: 发现僵尸部署锁 (>1小时)，建议手动清理: rm /var/lib/openclaw/deploy-locks/<app>.lock"
fi

# ============================================================
# G 阶段：跨机部署预检（F-1/2/3/4/9 本机可推断部分）
# ============================================================

# F-1: deploy-locks 目录可写（deploy 用户要能创建 lock）
LOCK_DIR="/var/lib/openclaw/deploy-locks"
if [ -d "$LOCK_DIR" ]; then
    if [ -w "$LOCK_DIR" ]; then
        : # ok
    else
        echo "WARN: $LOCK_DIR 当前用户不可写（F-1）：sudo chmod 1777 $LOCK_DIR  或 sudo chown $(whoami) $LOCK_DIR"
    fi
else
    echo "WARN: $LOCK_DIR 不存在（deploy.sh 会自建但需 mkdir -p 权限）"
fi

# F-2: apps.json / environments.json 权限（deploy 用户要能读）
for _f in "$APPS_JSON" "$ENVS_JSON"; do
    if [ -f "$_f" ]; then
        _perm=$(stat -c '%a' "$_f" 2>/dev/null || echo "")
        _grp=$(stat -c '%G' "$_f" 2>/dev/null || echo "")
        if [ "$_perm" = "600" ] || [ "$_perm" = "640" ]; then
            if [ "$_grp" != "deploy" ] && [ "$_grp" != "openclaw" ]; then
                echo "WARN: $_f 权限=$_perm 组=$_grp（F-2）：deploy 用户可能读不了。试：sudo chgrp deploy $_f && sudo chmod 640 $_f"
            fi
        fi
    fi
done

# F-3 / F-4: 各项目 .git 目录为 deploy 用户可访问（仅在本机部署环境检查）
if [ "$DEPLOY_LOCAL_NEEDED" = "true" ] && [ -f "$APPS_JSON" ]; then
    while IFS= read -r _path; do
        [ -z "$_path" ] || [ "$_path" = "null" ] && continue
        if [ -d "$_path" ]; then
            # 推导仓根
            _gd="$_path"
            while [ -n "$_gd" ] && [ "$_gd" != "/" ] && [ ! -d "$_gd/.git" ]; do _gd=$(dirname "$_gd"); done
            if [ -d "$_gd/.git" ]; then
                _git_grp=$(stat -c '%G' "$_gd/.git" 2>/dev/null || echo "")
                _git_perm=$(stat -c '%a' "$_gd/.git" 2>/dev/null || echo "")
                if [ "$_git_grp" != "deploy" ] && [ "$_git_grp" != "openclaw" ]; then
                    echo "WARN: $_gd/.git 组=$_git_grp（F-4）：sudo chgrp -R deploy $_gd/.git && sudo chmod -R g+w $_gd/.git"
                fi
            fi
        fi
    done < <(jq -r '.apps[].env_config[]?.project_path // empty' "$APPS_JSON" 2>/dev/null)
fi

# F-9: pnpm 可执行
if ! command -v pnpm >/dev/null 2>&1; then
    if [ "$DEPLOY_LOCAL_NEEDED" = "true" ]; then
        echo "WARN: pnpm 不在 PATH（F-9）：sudo corepack enable; sudo npm i -g pnpm@9"
    fi
fi

# G 阶段：远端机检查（仅提示，不主动 SSH，避免 doctor 慢）
if [ "$DEPLOY_PROD_NEEDED" = "true" ]; then
    PROD_HOST=$(jq -r '.environments.prod.host // empty' "$ENVS_JSON" 2>/dev/null)
    if [ -n "$PROD_HOST" ]; then
        echo "INFO: 远端部署目标 prod=$PROD_HOST。首次部署前请跑: bash $SKILL_DIR/scripts/init-remote-target.sh root@$PROD_HOST --ssh-key ~/.ssh/<root_key>"
    fi
fi

echo "READY"
exit 0
