#!/bin/bash
# ===================================================
# SYN Defense System - One-Click Deployment Script
# ===================================================

set -euo pipefail

# Color definitions
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Script directory
SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"

echo -e "${BLUE}==========================================${NC}"
echo -e "${BLUE}  SYN Defense System - One-Click Deployment${NC}"
echo -e "${BLUE}==========================================${NC}"
echo ""

# Check permissions
if [ "$EUID" -ne 0 ]; then
    echo -e "${RED}❌ Please run as root user${NC}"
    exit 1
fi

# ===== Step 1: Create configuration directories =====
echo -e "${YELLOW}[1/8]${NC} Creating configuration directories..."
mkdir -p /etc/syn_defense/backup
mkdir -p /var/log
echo -e "  ${GREEN}✅ Configuration directories created${NC}"

# ===== Step 2: Copy configuration files =====
echo -e "${YELLOW}[2/8]${NC} Deploying configuration files..."

if [ ! -f /etc/syn_defense/whitelist.conf ]; then
    cp "${PROJECT_DIR}/config/whitelist.conf" /etc/syn_defense/whitelist.conf
    echo -e "  ${GREEN}✅ Whitelist configuration deployed${NC}"
else
    echo -e "  ${BLUE}ℹ️  Whitelist configuration already exists, skipping (update manually if needed)${NC}"
fi

if [ ! -f /etc/syn_defense/config.conf ]; then
    cp "${PROJECT_DIR}/config/config.conf" /etc/syn_defense/config.conf
    echo -e "  ${GREEN}✅ Parameter configuration deployed${NC}"
else
    echo -e "  ${BLUE}ℹ️  Parameter configuration already exists, skipping (update manually if needed)${NC}"
fi

# ===== Step 3: Deploy main script =====
echo -e "${YELLOW}[3/8]${NC} Deploying main script..."
cp "${PROJECT_DIR}/scripts/syn_defense.sh" /usr/local/bin/syn_defense.sh
chmod 755 /usr/local/bin/syn_defense.sh
echo -e "  ${GREEN}✅ Main script deployed to /usr/local/bin/syn_defense.sh${NC}"

# ===== Step 4: Install dependencies =====
echo -e "${YELLOW}[4/8]${NC} Checking and installing dependencies..."

check_and_install() {
    local cmd=$1
    local pkg=$2
    
    if ! command -v "$cmd" &>/dev/null; then
        echo -e "  Installing ${pkg}..."
        if command -v yum &>/dev/null; then
            yum install -y "$pkg" >/dev/null 2>&1
        elif command -v apt-get &>/dev/null; then
            apt-get update >/dev/null 2>&1
            apt-get install -y "$pkg" >/dev/null 2>&1
        else
            echo -e "  ${RED}❌ Unknown package manager${NC}"
            return 1
        fi
    else
        echo -e "  ${GREEN}✓${NC} $cmd already installed"
    fi
}

check_and_install "ipset" "ipset"
check_and_install "ss" "iproute"

echo -e "  ${GREEN}✅ Dependency check completed${NC}"

# ===== Step 5: Optimize kernel parameters =====
echo -e "${YELLOW}[5/8]${NC} Optimizing kernel parameters..."

cat > /etc/sysctl.d/99-syn-defense.conf <<'SYSCTL_EOF'
# ===== SYN Cookies (Core Protection) =====
net.ipv4.tcp_syncookies = 1
net.ipv4.tcp_max_syn_backlog = 8192
net.ipv4.tcp_synack_retries = 1
net.ipv4.tcp_syn_retries = 2

# ===== Conntrack Optimization =====
net.netfilter.nf_conntrack_max = 1000000
net.netfilter.nf_conntrack_tcp_timeout_syn_recv = 30
net.netfilter.nf_conntrack_tcp_timeout_time_wait = 30

# ===== TCP Performance Optimization =====
net.ipv4.tcp_fin_timeout = 15
net.ipv4.tcp_tw_reuse = 1
net.core.somaxconn = 8192
net.core.netdev_max_backlog = 10000

# ===== Security Hardening =====
net.ipv4.conf.all.rp_filter = 1
net.ipv4.conf.default.rp_filter = 1
net.ipv4.conf.all.accept_redirects = 0
net.ipv4.conf.default.accept_redirects = 0
SYSCTL_EOF

if sysctl -p /etc/sysctl.d/99-syn-defense.conf >/dev/null 2>&1; then
    echo -e "  ${GREEN}✅ Kernel parameters optimized${NC}"
else
    echo -e "  ${YELLOW}⚠️  Kernel parameter optimization failed (non-fatal error)${NC}"
fi

# ===== Step 6: Create systemd service =====
echo -e "${YELLOW}[6/8]${NC} Creating systemd service..."

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

# Security restrictions
NoNewPrivileges=false
PrivateTmp=true
ProtectSystem=strict
ProtectHome=true
ReadWritePaths=/var/log /var/run /etc/syn_defense

[Install]
WantedBy=multi-user.target
SERVICE_EOF

systemctl daemon-reload
echo -e "  ${GREEN}✅ systemd service created${NC}"

# ===== Step 7: Set permissions =====
echo -e "${YELLOW}[7/8]${NC} Setting permissions..."
chmod 755 /usr/local/bin/syn_defense.sh
chmod 644 /etc/syn_defense/*.conf
chmod 755 /etc/syn_defense
echo -e "  ${GREEN}✅ Permissions configured${NC}"

# ===== Step 8: Start service =====
echo -e "${YELLOW}[8/8]${NC} Starting service..."

# Ask if should start immediately
read -p "Start defense service now? (y/n): " -n 1 -r
echo ""

if [[ $REPLY =~ ^[Yy]$ ]]; then
    systemctl enable syn-defense >/dev/null 2>&1
    systemctl start syn-defense
    
    # Wait for service to start
    sleep 2
    
    if systemctl is-active --quiet syn-defense; then
        echo -e "  ${GREEN}✅ Service started successfully${NC}"
    else
        echo -e "  ${RED}❌ Service failed to start${NC}"
        echo -e "  View logs: ${YELLOW}journalctl -u syn-defense -f${NC}"
        exit 1
    fi
else
    echo -e "  ${BLUE}ℹ️  Service not started, you can start it later: systemctl start syn-defense${NC}"
fi

echo ""
echo -e "${GREEN}==========================================${NC}"
echo -e "${GREEN}  🎉 Deployment Complete!${NC}"
echo -e "${GREEN}==========================================${NC}"
echo ""
echo -e "${BLUE}📋 Common Commands:${NC}"
echo -e "  View service status:  ${YELLOW}systemctl status syn-defense${NC}"
echo -e "  View real-time logs:  ${YELLOW}tail -f /var/log/syn_defense.log${NC}"
echo -e "  View system logs:     ${YELLOW}journalctl -u syn-defense -f${NC}"
echo -e "  View blacklist:       ${YELLOW}ipset list syn_blacklist${NC}"
echo -e "  View whitelist:       ${YELLOW}ipset list syn_whitelist${NC}"
echo -e "  Manual scan:          ${YELLOW}/usr/local/bin/syn_defense.sh once${NC}"
echo ""
echo -e "${BLUE}📝 Configuration Files:${NC}"
echo -e "  Whitelist config:     ${YELLOW}/etc/syn_defense/whitelist.conf${NC}"
echo -e "  Parameter config:     ${YELLOW}/etc/syn_defense/config.conf${NC}"
echo ""
echo -e "${BLUE}🔧 Management Commands:${NC}"
echo -e "  Start service:        ${YELLOW}systemctl start syn-defense${NC}"
echo -e "  Stop service:         ${YELLOW}systemctl stop syn-defense${NC}"
echo -e "  Restart service:      ${YELLOW}systemctl restart syn-defense${NC}"
echo -e "  Enable auto-start:    ${YELLOW}systemctl enable syn-defense${NC}"
echo -e "  Disable auto-start:   ${YELLOW}systemctl disable syn-defense${NC}"
echo ""
echo -e "${YELLOW}⚠️  Important Notes:${NC}"
echo -e "  1. Whitelist changes take effect automatically, no service restart needed"
echo -e "  2. Parameter config changes require service restart"
echo -e "  3. Recommended to set ENABLE_BLOCK=0 and observe for 24 hours on first run"
echo -e "  4. If issues occur, execute rollback script: ${YELLOW}bash rollback.sh${NC}"
echo ""
