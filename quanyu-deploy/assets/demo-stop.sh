#!/bin/bash
set -e
PROJECT="__PROJECT_NAME__"
PORT="__PORT__"

echo "⏹️ 停止演示项目: $PROJECT"
cd "$(dirname "$0")"

# 1. 停止容器
docker compose down

# 2. 关闭端口（本地防火墙）
sudo iptables -D INPUT -p tcp --dport $PORT -j ACCEPT 2>/dev/null && echo "🔒 端口 $PORT 已关闭" || echo "⚠️ 端口规则不存在（可能已关闭）"

echo "✅ 已停止 | 数据已保留在 demo-data/"
