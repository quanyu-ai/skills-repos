#!/bin/bash
# doctor.sh - deploy-app skill 自检脚本
# 输出格式：最后一行 READY 或 NEED_SETUP: <原因>
# 退出码：0 = READY, 1 = NEED_SETUP

set -e

SKILL_DIR="$(cd "$(dirname "$0")/.." && pwd)"
CONFIG_DIR="$SKILL_DIR/config"

fail() {
    echo "NEED_SETUP: $1"
    exit 1
}

# 前置：jq 必装（否则后面的 JSON 校验跑不动）
command -v jq >/dev/null 2>&1 || fail "jq not installed - run: sudo apt-get install -y jq"

# 检查项 1：apps.json 存在
[ -f "$CONFIG_DIR/apps.json" ] || fail "apps.json missing - run setup.md step 2"

# 检查项 2：environments.json 存在
[ -f "$CONFIG_DIR/environments.json" ] || fail "environments.json missing - run setup.md step 2"

# 检查项 3：apps.json JSON 格式有效
jq empty "$CONFIG_DIR/apps.json" 2>/dev/null || fail "apps.json invalid JSON"

# 检查项 4：environments.json JSON 格式有效
jq empty "$CONFIG_DIR/environments.json" 2>/dev/null || fail "environments.json invalid JSON"

# 检查项 5：本机 SSH 密钥
[ -f "$HOME/.ssh/deploy_local" ] || fail "SSH deploy_local key missing - run setup.md step 5"

# 检查项 6：本机 SSH 联通
ssh -i "$HOME/.ssh/deploy_local" \
    -o BatchMode=yes \
    -o ConnectTimeout=5 \
    -o StrictHostKeyChecking=no \
    deploy@localhost true 2>/dev/null \
    || fail "SSH localhost not configured - run setup.md step 5"

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

echo "READY"
exit 0
