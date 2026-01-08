#!/bin/bash
# ===================================================
# SYN Defense System - Emergency Rollback Script
# ===================================================

set -e

# Color definitions
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

echo -e "${RED}=========================================="
echo -e "  🚨 SYN Defense System - Emergency Rollback"
echo -e "==========================================${NC}"
echo ""

# Confirm operation
read -p "Confirm rollback? This will stop the defense service and clear all rules. (yes/no): " confirm

if [ "$confirm" != "yes" ]; then
    echo -e "${YELLOW}Rollback cancelled${NC}"
    exit 0
fi

echo ""
echo -e "${YELLOW}Starting rollback...${NC}"
echo ""

# ===== Step 1: Stop service =====
echo -e "[1/6] Stopping defense service..."
if systemctl stop syn-defense 2>/dev/null; then
    echo -e "  ${GREEN}✅ Service stopped${NC}"
else
    echo -e "  ${YELLOW}⚠️  Service not running or stop failed${NC}"
fi

# Force kill processes
pkill -f syn_defense.sh 2>/dev/null || true
echo -e "  ${GREEN}✅ Related processes cleaned${NC}"

# ===== Step 2: Flush blacklists =====
echo -e "[2/6] Flushing blacklists..."
if ipset flush syn_blacklist 2>/dev/null; then
    echo -e "  ${GREEN}✅ IP blacklist flushed${NC}"
else
    echo -e "  ${YELLOW}⚠️  IP blacklist doesn't exist or flush failed${NC}"
fi

if ipset flush syn_blacklist_subnet 2>/dev/null; then
    echo -e "  ${GREEN}✅ Subnet blacklist flushed${NC}"
else
    echo -e "  ${YELLOW}⚠️  Subnet blacklist doesn't exist or flush failed${NC}"
fi

# ===== Step 3: Remove iptables rules =====
echo -e "[3/6] Removing iptables rules..."

# Remove whitelist rule
if iptables -D INPUT -m set --match-set syn_whitelist src -j ACCEPT 2>/dev/null; then
    echo -e "  ${GREEN}✅ Whitelist rule removed${NC}"
else
    echo -e "  ${YELLOW}⚠️  Whitelist rule doesn't exist${NC}"
fi

# Remove blacklist rule
if iptables -D INPUT -m set --match-set syn_blacklist src -j DROP 2>/dev/null; then
    echo -e "  ${GREEN}✅ IP blacklist rule removed${NC}"
else
    echo -e "  ${YELLOW}⚠️  IP blacklist rule doesn't exist${NC}"
fi

# Remove subnet blacklist rule
if iptables -D INPUT -m set --match-set syn_blacklist_subnet src -j DROP 2>/dev/null; then
    echo -e "  ${GREEN}✅ Subnet blacklist rule removed${NC}"
else
    echo -e "  ${YELLOW}⚠️  Subnet blacklist rule doesn't exist${NC}"
fi

# Remove connection limit rule
if iptables -D INPUT -p tcp --syn -m connlimit --connlimit-above 100 --connlimit-mask 32 -j DROP 2>/dev/null; then
    echo -e "  ${GREEN}✅ Connection limit rule removed${NC}"
else
    echo -e "  ${YELLOW}⚠️  Connection limit rule doesn't exist${NC}"
fi

# ===== Step 4: Remove ipsets =====
echo -e "[4/6] Removing ipsets..."

if ipset destroy syn_blacklist 2>/dev/null; then
    echo -e "  ${GREEN}✅ syn_blacklist removed${NC}"
else
    echo -e "  ${YELLOW}⚠️  syn_blacklist doesn't exist${NC}"
fi

if ipset destroy syn_blacklist_subnet 2>/dev/null; then
    echo -e "  ${GREEN}✅ syn_blacklist_subnet removed${NC}"
else
    echo -e "  ${YELLOW}⚠️  syn_blacklist_subnet doesn't exist${NC}"
fi

if ipset destroy syn_whitelist 2>/dev/null; then
    echo -e "  ${GREEN}✅ syn_whitelist removed${NC}"
else
    echo -e "  ${YELLOW}⚠️  syn_whitelist doesn't exist${NC}"
fi

# ===== Step 5: Clean temporary files =====
echo -e "[5/6] Cleaning temporary files..."
rm -f /var/run/syn_defense.lock 2>/dev/null || true
rm -f /var/run/syn_defense.pid 2>/dev/null || true
rm -f /var/run/syn_whitelist.md5 2>/dev/null || true
echo -e "  ${GREEN}✅ Temporary files cleaned${NC}"

# ===== Step 6: Log rollback =====
echo -e "[6/6] Logging rollback..."
logger -t syn_defense "Emergency rollback executed at $(date '+%Y-%m-%d %H:%M:%S')"

if [ -f /var/log/syn_defense.log ]; then
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] [ROLLBACK] Emergency rollback executed" >> /var/log/syn_defense.log
fi

echo -e "  ${GREEN}✅ Logged${NC}"

echo ""
echo -e "${GREEN}=========================================="
echo -e "  ✅ Rollback Complete"
echo -e "==========================================${NC}"
echo ""
echo -e "${YELLOW}Notes:${NC}"
echo "  1. Defense service completely stopped"
echo "  2. All defense rules cleared"
echo "  3. Configuration files still preserved in /etc/syn_defense/"
echo "  4. To restart, execute: systemctl start syn-defense"
echo ""
echo -e "${YELLOW}For complete uninstallation:${NC}"
echo "  1. Remove service: systemctl disable syn-defense && rm /etc/systemd/system/syn-defense.service"
echo "  2. Remove script: rm /usr/local/bin/syn_defense.sh"
echo "  3. Remove config: rm -rf /etc/syn_defense"
echo "  4. Remove logs: rm /var/log/syn_defense.log"
echo ""
