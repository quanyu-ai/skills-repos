---
name: role-tester
description: 测试工程师岗位技能。当任务涉及功能测试、验收检查、bug 验证时激活。
---

# 测试工程师岗位技能

## 职责
模拟真实用户操作，验证系统可用，不是检查"能不能打开"，而是检查"能不能用"。

## 测试三层（全部必做，缺一不可）

### 第一层：表面测试（页面+API）
- 每个页面 HTTP 200
- 每个 API 端点能响应

### 第二层：数据真实性测试（扫硬编码）
```bash
# 扫描前端硬编码
grep -rn "张老板\|深圳华创\|sys-\|mock\|示例数据\|开发中" apps/*/src/ | grep -v node_modules

# 扫描 API 硬编码
grep -rn "systemCategories\|硬编码\|mock\|Mock" packages/api/src/ | grep -v node_modules

# 检查 API 返回的 id 和数据库 id 是否一致
# 对比 API 返回 vs 数据库实际数据
```

### 第三层：用户操作流程测试（最重要！）

**模拟用户完整操作，不是直接调 API：**

1. **记账流程**：
   - 调 category.list 获取分类 → 拿到第一个分类的 id
   - 用这个 id 调 record.create → 验证成功
   - 调 record.list → 验证刚才的记录在列表中
   
2. **发票流程**：
   - 调 invoice.create 上传发票 → 验证成功
   - 调 invoice.list → 验证刚才的发票在列表中
   - 调 invoice.stats → 验证计数增加

3. **查看流程**：
   - 调 stats.summary → 验证金额包含刚才记的账
   - 调 stats.recentRecords → 验证最近记录有刚才的

**关键：用 API A 返回的 id 作为 API B 的输入，模拟前端的真实调用链路。**

### 测试脚本模板
```bash
BASE="http://localhost:PORT/api/trpc"

# 1. 获取分类（模拟前端下拉框）
CAT_ID=$(curl -s "$BASE/category.list" | python3 -c "
import sys,json
cats = json.load(sys.stdin)['result']['data']['json']
expense_cats = [c for c in cats if c['type'] == 'EXPENSE']
print(expense_cats[0]['id'] if expense_cats else 'NONE')
")
echo "分类ID: $CAT_ID"

# 2. 用这个分类ID记账（模拟用户选分类→记账）
RESULT=$(curl -s -X POST "$BASE/record.create" \
  -H "Content-Type: application/json" \
  -d "{\"json\":{\"bookId\":\"default-book-id\",\"amount\":100,\"type\":\"EXPENSE\",\"categoryId\":\"$CAT_ID\",\"date\":\"$(date -I)T00:00:00.000Z\",\"source\":\"MANUAL\"}}")
echo "记账: $(echo $RESULT | python3 -c "import sys,json; d=json.load(sys.stdin); print('✅' if 'result' in d else '❌ '+str(d.get('error',{}).get('json',{}).get('message',''))[:80])")"

# 3. 验证列表中有这条记录
echo "列表: $(curl -s "$BASE/record.list?input=%7B%22json%22%3A%7B%22page%22%3A1%7D%7D" | python3 -c "import sys,json; d=json.load(sys.stdin); print('✅ '+str(len(d['result']['data']['json']['records']))+'条') if 'result' in d else print('❌')")"
```

## 禁止
- ❌ 只测 HTTP 200 就说"通过"
- ❌ 直接写死正确的 id 调 API（必须从上一步 API 获取）
- ❌ 不检查硬编码就说"无问题"
- ❌ 不做用户流程测试就出报告

详见 `guides/product-dev-workflow.md` Phase 9

### 边界测试（必做）
核心操作必须测以下边界情况：
- [ ] 不选分类直接提交
- [ ] 金额为空/为0/为负数
- [ ] 商户名为空
- [ ] 日期为空
- [ ] 超长文本输入
