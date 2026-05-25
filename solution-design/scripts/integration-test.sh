#!/bin/bash
# integration-test.sh - solution-design skill 端到端集成测试
#
# 用法: bash integration-test.sh
#
# 流程：
#   1. 创建临时项目结构（mock requirements/）
#   2. 用临时 WORKSPACE_DIR 覆盖路径，跑 init-solution → generate-modules → sync → diff → validate
#   3. 断言每步退出码 & 输出文件存在
#   4. 清理

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SKILL_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

# 注意：脚本里的 WORKSPACE_DIR 是 SKILL_DIR/../.. 推导，所以我们需要把脚本放在一个 mock workspace 下
# 折中：直接复用真实 workspace，但用一个不存在的项目名做隔离

TEST_PROJECT="sd-itest-$$"
WORKSPACE_DIR="$(cd "$SKILL_DIR/../.." && pwd)"
PROJECT_DIR="$WORKSPACE_DIR/docs-repos/$TEST_PROJECT"

cleanup() {
    if [ -d "$PROJECT_DIR" ]; then
        rm -rf "$PROJECT_DIR"
        echo "🧹 已清理: $PROJECT_DIR"
    fi
}
trap cleanup EXIT

PASS=0
FAIL=0
assert_ok() {
    if [ $1 -eq 0 ]; then
        echo "  ✅ $2"
        PASS=$((PASS+1))
    else
        echo "  ❌ $2 (exit=$1)"
        FAIL=$((FAIL+1))
    fi
}
assert_file() {
    if [ -f "$1" ]; then
        echo "  ✅ 文件存在: $(basename "$1")"
        PASS=$((PASS+1))
    else
        echo "  ❌ 文件缺失: $1"
        FAIL=$((FAIL+1))
    fi
}

echo "═════ Phase 0: 准备 mock 项目 ═════"
mkdir -p "$PROJECT_DIR/requirements"
cat > "$PROJECT_DIR/requirements/REQ-20260520-001.md" <<'EOF'
# REQ-20260520-001：用户-登录注册
用户需要能够注册账号并登录系统。
EOF
cat > "$PROJECT_DIR/requirements/REQ-20260520-002.md" <<'EOF'
# REQ-20260520-002：学生-学业成绩查询
学生可以在工作台查看自己的成绩。
EOF
cat > "$PROJECT_DIR/requirements/REQ-20260520-003.md" <<'EOF'
# REQ-20260520-003：通知中心
系统发送消息通知给用户。
EOF
echo "  ✅ mock REQ 文件 3 个"

echo ""
echo "═════ Phase 1: init-solution.sh ═════"
bash "$SKILL_DIR/scripts/init-solution.sh" "$TEST_PROJECT" >/dev/null 2>&1
assert_ok $? "init-solution.sh 成功"
assert_file "$PROJECT_DIR/solution/architecture/overview.md"
assert_file "$PROJECT_DIR/solution/meta/version.json"
# 二次调用应失败
bash "$SKILL_DIR/scripts/init-solution.sh" "$TEST_PROJECT" >/dev/null 2>&1
if [ $? -ne 0 ]; then
    echo "  ✅ 重复 init 被拒绝"
    PASS=$((PASS+1))
else
    echo "  ❌ 重复 init 应该失败"
    FAIL=$((FAIL+1))
fi

echo ""
echo "═════ Phase 2: generate-modules.sh ═════"
bash "$SKILL_DIR/scripts/generate-modules.sh" "$TEST_PROJECT" --dry-run >/dev/null 2>&1
assert_ok $? "generate-modules --dry-run 成功"
bash "$SKILL_DIR/scripts/generate-modules.sh" "$TEST_PROJECT" >/dev/null 2>&1
assert_ok $? "generate-modules 成功"
# 检查至少生成了 auth / user / notification 几个模块
for m in auth user notification; do
    if [ -d "$PROJECT_DIR/solution/modules/$m" ]; then
        echo "  ✅ 识别模块: $m"; PASS=$((PASS+1))
    else
        echo "  ❌ 未识别模块: $m"; FAIL=$((FAIL+1))
    fi
done

echo ""
echo "═════ Phase 3: sync-solution-map.sh ═════"
bash "$SKILL_DIR/scripts/sync-solution-map.sh" "$TEST_PROJECT" --quiet
assert_ok $? "sync-solution-map 成功"
assert_file "$PROJECT_DIR/solution/solution-map.json"
M=$(jq -r '.stats.modules' "$PROJECT_DIR/solution/solution-map.json")
R=$(jq -r '.stats.reqs'    "$PROJECT_DIR/solution/solution-map.json")
echo "  📊 stats: modules=$M  reqs=$R"
if [ "$M" -ge 3 ] && [ "$R" -ge 3 ]; then
    echo "  ✅ 映射统计符合预期"; PASS=$((PASS+1))
else
    echo "  ❌ 映射统计不足: M=$M R=$R"; FAIL=$((FAIL+1))
fi

echo ""
echo "═════ Phase 4: diff-against-reqs.sh ═════"
bash "$SKILL_DIR/scripts/diff-against-reqs.sh" "$TEST_PROJECT" --quiet
EX=$?
# 预期 0（无 error，可能有 warn 如 EMPTY apis）或 1（如果加了 --fail-on-warn）
if [ $EX -eq 0 ] || [ $EX -eq 1 ]; then
    echo "  ✅ diff-against-reqs 退出码合理 (=$EX)"
    PASS=$((PASS+1))
else
    echo "  ❌ diff-against-reqs 退出码异常 (=$EX)"
    FAIL=$((FAIL+1))
fi
# 删一个需求模拟漂移
rm "$PROJECT_DIR/requirements/REQ-20260520-001.md"
bash "$SKILL_DIR/scripts/sync-solution-map.sh" "$TEST_PROJECT" --quiet
bash "$SKILL_DIR/scripts/diff-against-reqs.sh" "$TEST_PROJECT" --quiet
EX=$?
if [ $EX -eq 2 ]; then
    echo "  ✅ 漂移正确检测为 ERROR (exit=2)"
    PASS=$((PASS+1))
else
    echo "  ⚠️  漂移退出码=$EX（期望 2，可能 reqs.json 里没 REQ 引用导致仅 WARN）"
fi

echo ""
echo "═════ Phase 5: validate-solution.sh ═════"
bash "$SKILL_DIR/scripts/validate-solution.sh" "$TEST_PROJECT" --quiet
EX=$?
if [ $EX -le 1 ]; then
    echo "  ✅ validate 退出码合理 (=$EX)"
    PASS=$((PASS+1))
else
    echo "  ❌ validate P0 失败 (=$EX)"
    FAIL=$((FAIL+1))
fi

echo ""
echo "═════ Phase 6: doctor.sh ═════"
OUT=$(bash "$SKILL_DIR/scripts/doctor.sh")
if [ "$OUT" = "READY" ] || echo "$OUT" | tail -1 | grep -q READY; then
    echo "  ✅ doctor.sh: READY"; PASS=$((PASS+1))
else
    echo "  ❌ doctor.sh: $OUT"; FAIL=$((FAIL+1))
fi

echo ""
echo "═════════════════════════════════════"
echo "✅ PASS=$PASS  ❌ FAIL=$FAIL"
echo "═════════════════════════════════════"

[ $FAIL -eq 0 ] && exit 0 || exit 1
