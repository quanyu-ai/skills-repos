#!/bin/bash
cd "$(dirname "$0")"
echo "📋 演示项目: __PROJECT_NAME__"
docker compose ps
echo ""
docker stats --no-stream demo-__PROJECT_NAME__ 2>/dev/null || true
