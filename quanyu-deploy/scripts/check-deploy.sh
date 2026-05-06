#!/bin/bash
# 权舆科技部署合规检查脚本
# 用法: bash check-deploy.sh /opt/demo/<project-name> [monorepo-root]

set -e
DEPLOY_DIR="${1:?用法: bash check-deploy.sh /opt/demo/<project-name> [monorepo-root]}"
MONOREPO_ROOT="${2:-}"
ERRORS=0
WARNINGS=0

echo "========== 部署合规检查 =========="
echo "检查目录: $DEPLOY_DIR"
echo ""

# 1. 必要文件检查
echo "📋 文件完整性检查:"
for f in docker-compose.yml demo-start.sh demo-stop.sh demo-status.sh README.md DEPLOY-LOG.md; do
    if [ -f "$DEPLOY_DIR/$f" ]; then
        echo "  ✅ $f"
    else
        echo "  ❌ $f 缺失"
        ERRORS=$((ERRORS + 1))
    fi
done

if [ -d "$DEPLOY_DIR/demo-data" ]; then
    echo "  ✅ demo-data/"
else
    echo "  ⚠️ demo-data/ 不存在"
    WARNINGS=$((WARNINGS + 1))
fi

echo ""

# 2. docker-compose.yml 检查
echo "🐳 docker-compose.yml 检查:"
COMPOSE="$DEPLOY_DIR/docker-compose.yml"
if [ -f "$COMPOSE" ]; then
    # restart 策略
    if grep -q 'restart: "no"' "$COMPOSE" || grep -q "restart: 'no'" "$COMPOSE"; then
        echo "  ✅ restart: no（演示环境）"
    elif grep -q 'restart:' "$COMPOSE"; then
        echo "  ❌ restart 不是 'no'（演示环境必须为 no）"
        ERRORS=$((ERRORS + 1))
    else
        echo "  ⚠️ 未声明 restart（建议显式声明）"
        WARNINGS=$((WARNINGS + 1))
    fi

    # 资源限制
    if grep -q 'memory:' "$COMPOSE"; then
        echo "  ✅ 有内存限制"
    else
        echo "  ❌ 缺少内存限制"
        ERRORS=$((ERRORS + 1))
    fi

    # build context
    if grep -q 'build: \.' "$COMPOSE" || grep -q "build: '.'" "$COMPOSE"; then
        echo "  ❌ build context 指向部署目录（应指向 monorepo 根目录）"
        ERRORS=$((ERRORS + 1))
    elif grep -q 'context:' "$COMPOSE"; then
        BUILD_CTX=$(grep 'context:' "$COMPOSE" | head -1 | sed 's/.*context:\s*//' | tr -d ' ')
        if echo "$BUILD_CTX" | grep -qE "/tmp|build-context|\.\/$"; then
            echo "  ❌ build context 指向临时/子目录"
            ERRORS=$((ERRORS + 1))
        else
            echo "  ✅ build context: $BUILD_CTX"
        fi
    fi

    # 容器命名
    if grep -q 'container_name: demo-' "$COMPOSE"; then
        echo "  ✅ 容器命名 demo- 前缀"
    else
        echo "  ❌ 容器命名不符合规范"
        ERRORS=$((ERRORS + 1))
    fi

    # 镜像标签
    if grep -q 'image: quanyu/' "$COMPOSE"; then
        echo "  ✅ 有镜像标签"
    else
        echo "  ⚠️ 未指定镜像标签（建议加上 image: quanyu/<project>:<version>）"
        WARNINGS=$((WARNINGS + 1))
    fi
fi

echo ""

# 3. 脚本权限
echo "🔧 脚本权限检查:"
for f in demo-start.sh demo-stop.sh demo-status.sh; do
    if [ -x "$DEPLOY_DIR/$f" ]; then
        echo "  ✅ $f 可执行"
    elif [ -f "$DEPLOY_DIR/$f" ]; then
        echo "  ❌ $f 不可执行（chmod +x）"
        ERRORS=$((ERRORS + 1))
    fi
done

echo ""

# 4. 版本一致性检查（如提供 monorepo 路径）
if [ -n "$MONOREPO_ROOT" ] && [ -f "$DEPLOY_DIR/DEPLOY-LOG.md" ]; then
    echo "🏷️ 版本一致性检查:"
    DEPLOY_VER=$(grep -oP 'v\d+\.\d+\.\d+' "$DEPLOY_DIR/DEPLOY-LOG.md" | tail -1)
    if [ -n "$DEPLOY_VER" ]; then
        echo "  DEPLOY-LOG 版本: $DEPLOY_VER"

        # 检查 git tag
        cd "$MONOREPO_ROOT" 2>/dev/null
        if git tag -l "*/$DEPLOY_VER" 2>/dev/null | grep -q "$DEPLOY_VER"; then
            echo "  ✅ git tag 存在"
        else
            echo "  ⚠️ git tag 不存在（建议补打 tag）"
            WARNINGS=$((WARNINGS + 1))
        fi

        # 检查未提交的修改
        if [ -z "$(git status --porcelain 2>/dev/null)" ]; then
            echo "  ✅ 代码已全部提交"
        else
            echo "  ❌ 有未提交的代码修改"
            ERRORS=$((ERRORS + 1))
        fi
    fi
    echo ""
fi

# 5. 结果
echo "========== 检查结果 =========="
if [ $ERRORS -eq 0 ] && [ $WARNINGS -eq 0 ]; then
    echo "✅ 全部通过！"
elif [ $ERRORS -eq 0 ]; then
    echo "⚠️ 通过，有 $WARNINGS 个警告。"
else
    echo "❌ 发现 $ERRORS 个错误，$WARNINGS 个警告。请修复后重新检查。"
    exit 1
fi
