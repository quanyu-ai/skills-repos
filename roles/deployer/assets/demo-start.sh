#!/bin/bash
set -e
PROJECT="__PROJECT_NAME__"
PORT="__PORT__"

echo "🚀 启动演示项目: $PROJECT"
cd "$(dirname "$0")"

# 1. 资源预检
MEM_AVAILABLE=$(free -m | awk '/Mem:/ {print $7}')
if [ "$MEM_AVAILABLE" -lt 300 ]; then
    echo "⚠️ 可用内存不足 300MB（当前 ${MEM_AVAILABLE}MB），请先关停其他演示项目："
    docker ps --filter "name=demo-" --format "  - {{.Names}} ({{.Status}})"
    exit 1
fi

# 2. 启动容器（首次会自动构建）
docker compose up -d

# 3. 开放端口（本地防火墙）
sudo iptables -C INPUT -p tcp --dport $PORT -j ACCEPT 2>/dev/null || sudo iptables -A INPUT -p tcp --dport $PORT -j ACCEPT
echo "🔓 端口 $PORT 已开放"

# 4. 健康检查
echo "⏳ 等待服务就绪..."
for i in $(seq 1 30); do
    if curl -sf http://localhost:$PORT > /dev/null 2>&1; then
        echo "✅ 已启动 | 访问: http://8.138.118.28:$PORT"
        docker compose ps
        exit 0
    fi
    sleep 1
done

echo "⚠️ 服务启动超时（30秒），请检查日志: docker compose logs"
docker compose ps
