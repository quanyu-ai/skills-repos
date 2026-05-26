#!/bin/bash
# init-remote-target.sh - 远端目标机一键初始化（G 阶段新增）
# 用法: init-remote-target.sh <user@host> [--ssh-key <path>] [--app <app_id>]
#
# 解决 F-6 / F-7 / F-8 三个跨机部署坑：
#   F-6: deploy 用户无 GitHub 部署密钥 -> 引导生成 + 输出公钥让用户去 GitHub 加
#   F-7: 远端无 deploy 用户 -> 远端建 deploy 用户 + sudoers + .ssh
#   F-8: sudo secure_path 不含 /usr/local/bin -> /etc/sudoers.d 修补
#
# 前提：必须用 root 或具备 sudo 的账号 SSH 到目标机
#
set -euo pipefail

C_R='\033[0;31m'; C_G='\033[0;32m'; C_Y='\033[1;33m'; C_B='\033[0;36m'; C_N='\033[0m'
log()     { printf "${C_B}▶ %s${C_N}\n" "$*"; }
log_ok()  { printf "${C_G}✓ %s${C_N}\n" "$*"; }
log_warn(){ printf "${C_Y}⚠ %s${C_N}\n" "$*"; }
log_err() { printf "${C_R}✗ %s${C_N}\n" "$*" >&2; }
die()     { log_err "$*"; exit 1; }

usage() {
    cat <<USAGE
Usage: $(basename "$0") <user@host> [--ssh-key <path>] [--app <app_id>]

Examples:
  # 用 root + ~/.ssh/id_ed25519 初始化腾讯云
  $(basename "$0") root@43.139.53.121 --ssh-key ~/.ssh/id_ed25519

  # 用 ubuntu + 默认密钥
  $(basename "$0") ubuntu@1.2.3.4

执行内容（在目标机上）：
  1. 建 deploy 用户（如不存在）
  2. 配 sudoers: deploy ALL=(ALL) NOPASSWD:ALL（用 /etc/sudoers.d/）
  3. 修 secure_path 包含 /usr/local/bin（F-8）
  4. 建 /home/deploy/.ssh 目录 + 配置文件权限
  5. 注入主控机当前用户的公钥到 deploy 的 authorized_keys
  6. 生成 deploy 用户的 SSH ed25519 密钥（如不存在，F-6）
  7. 输出 deploy 用户公钥（让用户去 GitHub Settings/Deploy Keys 添加）
  8. 安装 git / curl / build-essential / pnpm（如缺失，F-9）
  9. 建 /home/deploy/code-repos / deploys 工作目录
USAGE
    exit 1
}

TARGET=""
SSH_KEY=""
APP_ID=""

while [ $# -gt 0 ]; do
    case "$1" in
        -h|--help) usage ;;
        --ssh-key) SSH_KEY="$2"; shift 2 ;;
        --app)     APP_ID="$2"; shift 2 ;;
        *)
            if [ -z "$TARGET" ]; then TARGET="$1"; shift
            else die "未知参数: $1"; fi
            ;;
    esac
done

[ -n "$TARGET" ] || usage

SSH_OPTS=(-o StrictHostKeyChecking=no -o BatchMode=yes)
[ -n "$SSH_KEY" ] && SSH_OPTS+=(-i "${SSH_KEY/#\~/$HOME}")

log "目标: $TARGET   key: ${SSH_KEY:-default}"

# 1. SSH 探活
ssh "${SSH_OPTS[@]}" -o ConnectTimeout=5 "$TARGET" true \
    || die "SSH 连不上 $TARGET (key=$SSH_KEY)。请确认网络/密钥/防火墙"
log_ok "SSH 连通"

# 2. 注入主控机当前用户的公钥（用于后续以 deploy 身份登录）
LOCAL_PUB=""
for cand in "$HOME/.ssh/id_ed25519.pub" "$HOME/.ssh/id_rsa.pub" "$HOME/.ssh/deploy_local.pub" "$HOME/.ssh/deploy_prod.pub"; do
    [ -f "$cand" ] && LOCAL_PUB="$(cat "$cand")" && break
done
[ -n "$LOCAL_PUB" ] || die "本地没找到任何 .ssh/*.pub 公钥。请先 ssh-keygen -t ed25519"
log_ok "本地公钥: $(echo "$LOCAL_PUB" | awk '{print $1,$NF}')"

# 3. 主体：远端 bash 脚本一次性跑
REMOTE_INIT_SCRIPT=$(cat <<'REOF'
set -e
LOCAL_PUB_LINE='__LOCAL_PUB__'
DEPLOY_USER=deploy

# 3.1 建 deploy 用户（如不存在）
if id "$DEPLOY_USER" >/dev/null 2>&1; then
    echo "[remote] 用户 $DEPLOY_USER 已存在"
else
    echo "[remote] 创建用户 $DEPLOY_USER"
    sudo useradd -m -s /bin/bash "$DEPLOY_USER"
fi

# 3.2 sudoers: NOPASSWD（F-2 解决组权限的同时也修这里）
SUDOERS_FILE=/etc/sudoers.d/90-${DEPLOY_USER}
if ! sudo test -f "$SUDOERS_FILE"; then
    echo "[remote] 写 sudoers: $SUDOERS_FILE"
    echo "$DEPLOY_USER ALL=(ALL) NOPASSWD:ALL" | sudo tee "$SUDOERS_FILE" >/dev/null
    sudo chmod 0440 "$SUDOERS_FILE"
fi

# 3.3 F-8: secure_path 包含 /usr/local/bin (一般用 sudoers.d 覆盖)
SECURE_PATH_FILE=/etc/sudoers.d/91-secure-path
if ! sudo grep -qE '^Defaults\s+secure_path.*\/usr\/local\/bin' /etc/sudoers /etc/sudoers.d/* 2>/dev/null; then
    echo "[remote] 修 secure_path 包含 /usr/local/bin (F-8)"
    echo 'Defaults secure_path="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"' | sudo tee "$SECURE_PATH_FILE" >/dev/null
    sudo chmod 0440 "$SECURE_PATH_FILE"
fi

# 3.4 .ssh 目录 + authorized_keys
SSH_DIR=/home/${DEPLOY_USER}/.ssh
sudo mkdir -p "$SSH_DIR"
sudo chown ${DEPLOY_USER}:${DEPLOY_USER} "$SSH_DIR"
sudo chmod 700 "$SSH_DIR"
AUTH_KEYS="$SSH_DIR/authorized_keys"
sudo touch "$AUTH_KEYS"
sudo chown ${DEPLOY_USER}:${DEPLOY_USER} "$AUTH_KEYS"
sudo chmod 600 "$AUTH_KEYS"
# 注入主控机公钥（去重）
if ! sudo grep -qF "$LOCAL_PUB_LINE" "$AUTH_KEYS"; then
    echo "$LOCAL_PUB_LINE" | sudo tee -a "$AUTH_KEYS" >/dev/null
    echo "[remote] 已注入主控公钥到 deploy authorized_keys"
fi

# 3.5 F-6: deploy 用户 SSH 密钥（用于 git clone GitHub）
DEPLOY_PRIV="$SSH_DIR/id_ed25519"
if ! sudo test -f "$DEPLOY_PRIV"; then
    echo "[remote] 生成 deploy 用户 SSH 密钥 (ed25519)"
    sudo -u ${DEPLOY_USER} ssh-keygen -t ed25519 -N '' -f "$DEPLOY_PRIV" -C "deploy@$(hostname)"
fi

# 3.6 配 known_hosts 加 github.com
sudo -u ${DEPLOY_USER} bash -c "ssh-keyscan -t ed25519,rsa github.com 2>/dev/null >> $SSH_DIR/known_hosts; sort -u $SSH_DIR/known_hosts -o $SSH_DIR/known_hosts" || true

# 3.7 git safe.directory（F-3）+ pnpm（F-9）+ git/curl/build-essential
echo "[remote] 检查工具链: git / pnpm / build-essential"
which git >/dev/null 2>&1 || sudo apt-get install -y git 2>/dev/null || sudo yum install -y git 2>/dev/null || true
which curl >/dev/null 2>&1 || sudo apt-get install -y curl 2>/dev/null || sudo yum install -y curl 2>/dev/null || true
which gcc >/dev/null 2>&1 || sudo apt-get install -y build-essential 2>/dev/null || sudo yum groupinstall -y "Development Tools" 2>/dev/null || true

if ! sudo -u ${DEPLOY_USER} bash -lc "command -v pnpm" >/dev/null 2>&1; then
    echo "[remote] pnpm 不在 deploy PATH，尝试 corepack 启用 + npm install -g pnpm"
    if command -v corepack >/dev/null 2>&1; then
        sudo corepack enable >/dev/null 2>&1 || true
        sudo -u ${DEPLOY_USER} bash -lc "corepack prepare pnpm@latest --activate" 2>/dev/null || true
    fi
    if ! sudo -u ${DEPLOY_USER} bash -lc "command -v pnpm" >/dev/null 2>&1; then
        sudo npm install -g pnpm@9 2>/dev/null || echo "[remote][warn] pnpm 安装失败，需手工 sudo npm i -g pnpm"
    fi
fi
# 软链 pnpm 到 /usr/local/bin（部分 corepack 安装路径 sudo 调不到 - F-9）
PNPM_BIN=$(sudo -u ${DEPLOY_USER} bash -lc 'command -v pnpm' 2>/dev/null || true)
if [ -n "$PNPM_BIN" ] && [ ! -e /usr/local/bin/pnpm ]; then
    sudo ln -sf "$PNPM_BIN" /usr/local/bin/pnpm || true
    echo "[remote] 软链 pnpm: /usr/local/bin/pnpm -> $PNPM_BIN"
fi

# 3.8 git config --global --add safe.directory '*' （F-3）
sudo -u ${DEPLOY_USER} git config --global --add safe.directory '*' 2>/dev/null || true

# 3.9 工作目录
sudo -u ${DEPLOY_USER} mkdir -p /home/${DEPLOY_USER}/code-repos /home/${DEPLOY_USER}/deploys

# 3.10 输出 deploy 公钥（让用户加到 GitHub Deploy Keys）
echo "===DEPLOY_PUB_BEGIN==="
sudo cat "$SSH_DIR/id_ed25519.pub"
echo "===DEPLOY_PUB_END==="

echo "[remote] init-remote-target 完成"
REOF
)

# 替换占位
REMOTE_INIT_SCRIPT="${REMOTE_INIT_SCRIPT//__LOCAL_PUB__/$LOCAL_PUB}"

log "在远端 $TARGET 上执行初始化（F-2/3/6/7/8/9 一并处理）"
REMOTE_OUT=$(ssh "${SSH_OPTS[@]}" "$TARGET" bash -s <<<"$REMOTE_INIT_SCRIPT" 2>&1) \
    || { echo "$REMOTE_OUT"; die "远端初始化失败"; }

echo "$REMOTE_OUT"

# 抽出 deploy pub
DEPLOY_PUB=$(echo "$REMOTE_OUT" | awk '/===DEPLOY_PUB_BEGIN===/{flag=1;next}/===DEPLOY_PUB_END===/{flag=0}flag')

cat <<DONE

═══════════════════════════════════════════════════════
                init-remote-target 完成
═══════════════════════════════════════════════════════

下一步：
  1. 把下面这串公钥加到 GitHub:
     - 项目级: github.com/<org>/<repo> → Settings → Deploy keys → Add deploy key (read-only)
     - 或账号级: github.com → Settings → SSH and GPG keys

  --------- deploy@$TARGET 的公钥 ---------
$DEPLOY_PUB
  -----------------------------------------

  2. 测试 deploy 用户能否 SSH 到主机:
     ssh deploy@${TARGET#*@} -i ~/.ssh/<your_key> true

  3. 测试 deploy 用户能否 git clone GitHub:
     ssh deploy@${TARGET#*@} 'cd /home/deploy/code-repos && git clone git@github.com:quanyu-ai/proj-code-smartops.git'

  4. 跑跨机部署:
     bash skills/deploy-app/scripts/deploy.sh prod ${APP_ID:-<app>} --version vX.Y.Z --approved-by longge

═══════════════════════════════════════════════════════
DONE
