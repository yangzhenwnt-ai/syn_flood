#!/bin/bash
# ===================================================
# SYN Defense System - Complete Uninstall Script
# ===================================================

set -e

# Color definitions
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

echo -e "${RED}=========================================="
echo -e "  🗑️  SYN Defense System - Complete Uninstall"
echo -e "==========================================${NC}"
echo ""
echo -e "${YELLOW}⚠️  WARNING: This operation will delete all related files and configurations!${NC}"
echo ""

# Confirm operation
read -p "Confirm complete uninstallation? (yes/no): " confirm

if [ "$confirm" != "yes" ]; then
    echo -e "${YELLOW}Uninstall cancelled${NC}"
    exit 0
fi

echo ""
echo -e "${YELLOW}Starting uninstallation...${NC}"
echo ""

# Check permissions
if [ "$EUID" -ne 0 ]; then
    echo -e "${RED}❌ Please run as root user${NC}"
    exit 1
fi

# ===== Step 1: Stop and disable service =====
echo -e "[1/8] Stopping and disabling service..."
if systemctl is-active --quiet syn-defense 2>/dev/null; then
    systemctl stop syn-defense
    echo -e "  ${GREEN}✅ Service stopped${NC}"
else
    echo -e "  ${BLUE}ℹ️  Service not running${NC}"
fi

if systemctl is-enabled --quiet syn-defense 2>/dev/null; then
    systemctl disable syn-defense >/dev/null 2>&1
    echo -e "  ${GREEN}✅ Auto-start disabled${NC}"
else
    echo -e "  ${BLUE}ℹ️  Service not enabled${NC}"
fi

# Force kill processes
pkill -f syn_defense.sh 2>/dev/null || true
echo -e "  ${GREEN}✅ Related processes cleaned${NC}"

# ===== Step 2: Remove systemd service file =====
echo -e "[2/8] Removing systemd service file..."
if [ -f /etc/systemd/system/syn-defense.service ]; then
    rm -f /etc/systemd/system/syn-defense.service
    systemctl daemon-reload
    echo -e "  ${GREEN}✅ Service file removed${NC}"
else
    echo -e "  ${BLUE}ℹ️  Service file does not exist${NC}"
fi

# ===== Step 3: Clear iptables rules =====
echo -e "[3/8] Clearing iptables rules..."

if iptables -C INPUT -m set --match-set syn_whitelist src -j ACCEPT 2>/dev/null; then
    iptables -D INPUT -m set --match-set syn_whitelist src -j ACCEPT
    echo -e "  ${GREEN}✅ Whitelist rule removed${NC}"
else
    echo -e "  ${BLUE}ℹ️  Whitelist rule does not exist${NC}"
fi

if iptables -C INPUT -m set --match-set syn_blacklist src -j DROP 2>/dev/null; then
    iptables -D INPUT -m set --match-set syn_blacklist src -j DROP
    echo -e "  ${GREEN}✅ Blacklist rule removed${NC}"
else
    echo -e "  ${BLUE}ℹ️  Blacklist rule does not exist${NC}"
fi

if iptables -C INPUT -p tcp --syn -m connlimit --connlimit-above 100 --connlimit-mask 32 -j DROP 2>/dev/null; then
    iptables -D INPUT -p tcp --syn -m connlimit --connlimit-above 100 --connlimit-mask 32 -j DROP
    echo -e "  ${GREEN}✅ Connection limit rule removed${NC}"
else
    echo -e "  ${BLUE}ℹ️  Connection limit rule does not exist${NC}"
fi

# ===== Step 4: Remove ipsets =====
echo -e "[4/8] Removing ipsets..."

if ipset list syn_blacklist &>/dev/null; then
    ipset destroy syn_blacklist
    echo -e "  ${GREEN}✅ syn_blacklist removed${NC}"
else
    echo -e "  ${BLUE}ℹ️  syn_blacklist does not exist${NC}"
fi

if ipset list syn_whitelist &>/dev/null; then
    ipset destroy syn_whitelist
    echo -e "  ${GREEN}✅ syn_whitelist removed${NC}"
else
    echo -e "  ${BLUE}ℹ️  syn_whitelist does not exist${NC}"
fi

# ===== Step 5: Remove main script =====
echo -e "[5/8] Removing main script..."
if [ -f /usr/local/bin/syn_defense.sh ]; then
    rm -f /usr/local/bin/syn_defense.sh
    echo -e "  ${GREEN}✅ Main script removed${NC}"
else
    echo -e "  ${BLUE}ℹ️  Main script does not exist${NC}"
fi

# ===== Step 6: Remove configuration files =====
echo -e "[6/8] Removing configuration files..."

# Backup to temporary directory first (just in case)
if [ -d /etc/syn_defense ]; then
    BACKUP_DIR="/tmp/syn_defense_backup_$(date +%Y%m%d_%H%M%S)"
    mkdir -p "$BACKUP_DIR"
    cp -r /etc/syn_defense/* "$BACKUP_DIR/" 2>/dev/null || true
    echo -e "  ${YELLOW}ℹ️  Config backed up to: $BACKUP_DIR${NC}"
    
    rm -rf /etc/syn_defense
    echo -e "  ${GREEN}✅ Config directory removed${NC}"
else
    echo -e "  ${BLUE}ℹ️  Config directory does not exist${NC}"
fi

# ===== Step 7: Remove log files =====
echo -e "[7/8] Removing log files..."
if [ -f /var/log/syn_defense.log ]; then
    # Backup logs
    if [ -n "$BACKUP_DIR" ]; then
        cp /var/log/syn_defense.log "$BACKUP_DIR/" 2>/dev/null || true
    fi
    
    rm -f /var/log/syn_defense.log
    echo -e "  ${GREEN}✅ Log file removed${NC}"
else
    echo -e "  ${BLUE}ℹ️  Log file does not exist${NC}"
fi

# ===== Step 8: Remove kernel parameter config =====
echo -e "[8/8] Removing kernel parameter config..."
if [ -f /etc/sysctl.d/99-syn-defense.conf ]; then
    rm -f /etc/sysctl.d/99-syn-defense.conf
    echo -e "  ${GREEN}✅ Kernel parameter config removed${NC}"
else
    echo -e "  ${BLUE}ℹ️  Kernel parameter config does not exist${NC}"
fi

# Clean temporary files
rm -f /var/run/syn_defense.lock 2>/dev/null || true
rm -f /var/run/syn_defense.pid 2>/dev/null || true
rm -f /var/run/syn_whitelist.md5 2>/dev/null || true

# Log uninstallation
logger -t syn_defense "System completely uninstalled at $(date '+%Y-%m-%d %H:%M:%S')"

echo ""
echo -e "${GREEN}=========================================="
echo -e "  ✅ Uninstall Complete"
echo -e "==========================================${NC}"
echo ""

if [ -n "$BACKUP_DIR" ]; then
    echo -e "${YELLOW}📦 Backup Information:${NC}"
    echo -e "  Config and logs backed up to: ${YELLOW}$BACKUP_DIR${NC}"
    echo -e "  You can restore from backup directory if needed"
    echo ""
fi

echo -e "${BLUE}📋 Items Removed:${NC}"
echo "  ✅ systemd service file"
echo "  ✅ Main script (/usr/local/bin/syn_defense.sh)"
echo "  ✅ Config directory (/etc/syn_defense/)"
echo "  ✅ Log file (/var/log/syn_defense.log)"
echo "  ✅ Kernel parameter config"
echo "  ✅ iptables rules"
echo "  ✅ ipset sets"
echo ""

echo -e "${GREEN}🎉 SYN Defense System has been completely uninstalled!${NC}"
echo ""
