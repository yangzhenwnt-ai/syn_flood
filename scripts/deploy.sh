#!/bin/bash
# ===================================================
# SYN 防护系统 - 一键部署脚本
# ===================================================

set -euo pipefail

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# 脚本所在目录
SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"

echo -e "${BLUE}==========================================${NC}"
echo -e "${BLUE}  SYN 防护系统 - 一键部署${NC}"
echo -e "${BLUE}==========================================${NC}"
echo ""

# 检查权限
if [ "$EUID" -ne 0 ]; then
    echo -e "${RED}❌ 请使用 root 用户运行${NC}"
    exit 1
fi

# ===== 步骤1：创建配置目录 =====
echo -e "${YELLOW}[1/8]${NC} 创建配置目录..."
mkdir -p /etc/syn_defense/backup
mkdir -p /var/log
echo -e "  ${GREEN}✅ 配置目录已创建${NC}"

# ===== 步骤2：复制配置文件 =====
echo -e "${YELLOW}[2/8]${NC} 部署配置文件..."

if [ ! -f /etc/syn_defense/whitelist.conf ]; then
    cp "${PROJECT_DIR}/config/whitelist.conf" /etc/syn_defense/whitelist.conf
    echo -e "  ${GREEN}✅ 白名单配置已部署${NC}"
else
    echo -e "  ${BLUE}ℹ️  白名单配置已存在，跳过（如需更新请手动操作）${NC}"
fi

if [ ! -f /etc/syn_defense/config.conf ]; then
    cp "${PROJECT_DIR}/config/config.conf" /etc/syn_defense/config.conf
    echo -e "  ${GREEN}✅ 参数配置已部署${NC}"
else
    echo -e "  ${BLUE}ℹ️  参数配置已存在，跳过（如需更新请手动操作）${NC}"
fi

# ===== 步骤3：部署主脚本 =====
echo -e "${YELLOW}[3/8]${NC} 部署主脚本..."
cp "${PROJECT_DIR}/scripts/syn_defense.sh" /usr/local/bin/syn_defense.sh
chmod 755 /usr/local/bin/syn_defense.sh
echo -e "  ${GREEN}✅ 主脚本已部署到 /usr/local/bin/syn_defense.sh${NC}"

# ===== 步骤4：安装依赖 =====
echo -e "${YELLOW}[4/8]${NC} 检查并安装依赖..."

check_and_install() {
    local cmd=$1
    local pkg=$2
    
    if ! command -v "$cmd" &>/dev/null; then
        echo -e "  安装 ${pkg}..."
        if command -v yum &>/dev/null; then
            yum install -y "$pkg" >/dev/null 2>&1
        elif command -v apt-get &>/dev/null; then
            apt-get update >/dev/null 2>&1
            apt-get install -y "$pkg" >/dev/null 2>&1
        else
            echo -e "  ${RED}❌ 无法识别的包管理器${NC}"
            return 1
        fi
    else
        echo -e "  ${GREEN}✓${NC} $cmd 已安装"
    fi
}

check_and_install "ipset" "ipset"
check_and_install "ss" "iproute"

echo -e "  ${GREEN}✅ 依赖检查完成${NC}"

# ===== 步骤5：优化内核参数 =====
echo -e "${YELLOW}[5/8]${NC} 优化内核参数..."

cat > /etc/sysctl.d/99-syn-defense.conf <<'SYSCTL_EOF'
# ===== SYN Cookies (核心防护) =====
net.ipv4.tcp_syncookies = 1
net.ipv4.tcp_max_syn_backlog = 8192
net.ipv4.tcp_synack_retries = 1
net.ipv4.tcp_syn_retries = 2

# ===== Conntrack 优化 =====
net.netfilter.nf_conntrack_max = 1000000
net.netfilter.nf_conntrack_tcp_timeout_syn_recv = 30
net.netfilter.nf_conntrack_tcp_timeout_time_wait = 30

# ===== TCP 性能优化 =====
net.ipv4.tcp_fin_timeout = 15
net.ipv4.tcp_tw_reuse = 1
net.core.somaxconn = 8192
net.core.netdev_max_backlog = 10000

# ===== 安全加固 =====
net.ipv4.conf.all.rp_filter = 1
net.ipv4.conf.default.rp_filter = 1
net.ipv4.conf.all.accept_redirects = 0
net.ipv4.conf.default.accept_redirects = 0
SYSCTL_EOF

if sysctl -p /etc/sysctl.d/99-syn-defense.conf >/dev/null 2>&1; then
    echo -e "  ${GREEN}✅ 内核参数已优化${NC}"
else
    echo -e "  ${YELLOW}⚠️  内核参数优化失败（非致命错误）${NC}"
fi

# ===== 步骤6：创建 systemd 服务 =====
echo -e "${YELLOW}[6/8]${NC} 创建 systemd 服务..."

cat > /etc/systemd/system/syn-defense.service <<'SERVICE_EOF'
[Unit]
Description=SYN Defense Service
Documentation=https://github.com/your-repo/syn-defense
After=network.target

[Service]
Type=simple
ExecStart=/usr/local/bin/syn_defense.sh
Restart=always
RestartSec=10
StandardOutput=journal
StandardError=journal

# 安全限制
NoNewPrivileges=false
PrivateTmp=true
ProtectSystem=strict
ProtectHome=true
ReadWritePaths=/var/log /var/run /etc/syn_defense

[Install]
WantedBy=multi-user.target
SERVICE_EOF

systemctl daemon-reload
echo -e "  ${GREEN}✅ systemd 服务已创建${NC}"

# ===== 步骤7：设置权限 =====
echo -e "${YELLOW}[7/8]${NC} 设置权限..."
chmod 755 /usr/local/bin/syn_defense.sh
chmod 644 /etc/syn_defense/*.conf
chmod 755 /etc/syn_defense
echo -e "  ${GREEN}✅ 权限设置完成${NC}"

# ===== 步骤8：启动服务 =====
echo -e "${YELLOW}[8/8]${NC} 启动服务..."

# 询问是否立即启动
read -p "是否立即启动防护服务？(y/n): " -n 1 -r
echo ""

if [[ $REPLY =~ ^[Yy]$ ]]; then
    systemctl enable syn-defense >/dev/null 2>&1
    systemctl start syn-defense
    
    # 等待服务启动
    sleep 2
    
    if systemctl is-active --quiet syn-defense; then
        echo -e "  ${GREEN}✅ 服务启动成功${NC}"
    else
        echo -e "  ${RED}❌ 服务启动失败${NC}"
        echo -e "  查看日志: ${YELLOW}journalctl -u syn-defense -f${NC}"
        exit 1
    fi
else
    echo -e "  ${BLUE}ℹ️  服务未启动，稍后可手动启动: systemctl start syn-defense${NC}"
fi

echo ""
echo -e "${GREEN}==========================================${NC}"
echo -e "${GREEN}  🎉 部署完成！${NC}"
echo -e "${GREEN}==========================================${NC}"
echo ""
echo -e "${BLUE}📋 常用命令：${NC}"
echo -e "  查看服务状态:  ${YELLOW}systemctl status syn-defense${NC}"
echo -e "  查看实时日志:  ${YELLOW}tail -f /var/log/syn_defense.log${NC}"
echo -e "  查看系统日志:  ${YELLOW}journalctl -u syn-defense -f${NC}"
echo -e "  查看黑名单:    ${YELLOW}ipset list syn_blacklist${NC}"
echo -e "  查看白名单:    ${YELLOW}ipset list syn_whitelist${NC}"
echo -e "  手动执行扫描:  ${YELLOW}/usr/local/bin/syn_defense.sh once${NC}"
echo ""
echo -e "${BLUE}📝 配置文件：${NC}"
echo -e "  白名单配置:    ${YELLOW}/etc/syn_defense/whitelist.conf${NC}"
echo -e "  参数配置:      ${YELLOW}/etc/syn_defense/config.conf${NC}"
echo ""
echo -e "${BLUE}🔧 管理命令：${NC}"
echo -e "  启动服务:      ${YELLOW}systemctl start syn-defense${NC}"
echo -e "  停止服务:      ${YELLOW}systemctl stop syn-defense${NC}"
echo -e "  重启服务:      ${YELLOW}systemctl restart syn-defense${NC}"
echo -e "  开机自启:      ${YELLOW}systemctl enable syn-defense${NC}"
echo -e "  禁用自启:      ${YELLOW}systemctl disable syn-defense${NC}"
echo ""
echo -e "${YELLOW}⚠️  重要提示：${NC}"
echo -e "  1. 白名单修改后自动生效，无需重启服务"
echo -e "  2. 参数配置修改后需要重启服务"
echo -e "  3. 首次运行建议设置 ENABLE_BLOCK=0 观察24小时"
echo -e "  4. 如遇问题，执行回滚脚本: ${YELLOW}bash rollback.sh${NC}"
echo ""

