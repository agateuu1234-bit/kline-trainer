#!/usr/bin/env bash
set -uo pipefail

echo "=== NAS Environment Preflight ==="

# 1. 检查 .env 是否存在
if [ ! -f backend/.env ]; then
    echo "FAIL: backend/.env not found."
    echo ""
    echo "  操作步骤："
    echo "  1. 打开 Terminal"
    echo "  2. 粘贴: cp backend/.env.example backend/.env"
    echo "  3. 用文本编辑器打开 backend/.env"
    echo "  4. 把 192.168.1.xxx 改成你 NAS 的真实 IP 地址"
    echo "  5. 把 changeme 改成你想用的 PostgreSQL 密码"
    echo "  6. 保存文件，重新运行此脚本"
    exit 1
fi

source backend/.env

# 1b. 检查必需变量
for var in NAS_HOST POSTGRES_USER POSTGRES_PASSWORD POSTGRES_DB DB_URL; do
    if [ -z "${!var:-}" ]; then
        echo "FAIL: $var not set in backend/.env"
        echo "  请检查 backend/.env 中是否填写了所有变量"
        exit 1
    fi
done

# 2. 检查 NAS 网络可达
echo -n "Checking NAS network ($NAS_HOST)... "
if ping -c 1 -W 3 "$NAS_HOST" > /dev/null 2>&1; then
    echo "PASS"
else
    echo "FAIL: Cannot reach $NAS_HOST"
    echo "  可能原因：NAS 没开机 / IP 填错 / 不在同一网络"
    exit 1
fi

# 3. 检查 PostgreSQL 端口
echo -n "Checking PostgreSQL port ($NAS_HOST:5433)... "
if nc -z -w 3 "$NAS_HOST" 5433 2>/dev/null; then
    echo "PASS"
else
    echo "FAIL: Port 5433 not open on $NAS_HOST"
    echo "  可能原因：NAS 上 PostgreSQL Docker 容器未启动"
    echo "  操作：SSH 到 NAS 执行 cd backend && docker compose up -d"
    exit 1
fi

# 4. 检查 PostgreSQL 连接
echo -n "Checking PostgreSQL connection... "
if python3 -c "
import sys
try:
    import asyncio, asyncpg
    async def check():
        conn = await asyncpg.connect('$DB_URL')
        ver = await conn.fetchval('SELECT version()')
        await conn.close()
        return ver
    ver = asyncio.run(check())
    print(f'PASS (PostgreSQL {ver.split(chr(44))[0]})')
except Exception as e:
    print(f'FAIL: {e}')
    sys.exit(1)
" 2>&1; then
    true
else
    echo "  可能原因：密码不对 / 数据库名不对 / asyncpg 没安装"
    exit 1
fi

echo ""
echo "=== NAS Preflight: ALL PASS ==="
