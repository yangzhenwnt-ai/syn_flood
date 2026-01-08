#!/bin/bash
# ===================================================
# SYN Defense System - Test Script
# ===================================================

set -euo pipefail

# Color definitions
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

PASS=0
FAIL=0
WARN=0

# Test function
test_check() {
    local name="$1"
    local command="$2"
    local expected="${3:-0}"
    
    echo -n "  Test: $name ... "
    
    if eval "$command" >/dev/null 2>&1; then
        local result=$?
    else
        local result=$?
    fi
    
    if [ "$result" -eq "$expected" ]; then
        echo -e "${GREEN}✅ Passed${NC}"
        PASS=$((PASS + 1))
        return 0
    else
        echo -e "${RED}❌ Failed${NC}"
        FAIL=$((FAIL + 1))
        return 1
    fi
}

test_warn() {
    local name="$1"
    local message="$2"
    
    echo -e "  ${YELLOW}⚠️  $name: $message${NC}"
    WARN=$((WARN + 1))
}

echo -e "${BLUE}=========================================="
echo -e "  SYN Defense System - Environment Test"
echo -e "==========================================${NC}"
echo ""

# ===== Group 1: Basic Environment Check =====
echo -e "${BLUE}【Basic Environment Check】${NC}"

test_check "Root Permissions" "[ \$EUID -eq 0 ]"
test_check "ipset Installed" "command -v ipset"
test_check "iptables Installed" "command -v iptables"
test_check "ss Command Available" "command -v ss"

if command -v systemctl &>/dev/null; then
    echo -e "  ${GREEN}✅ systemd available${NC}"
    PASS=$((PASS + 1))
else
    test_warn "systemd" "Not installed or unavailable, may affect service management"
fi

echo ""

# ===== Group 2: Kernel Parameter Check =====
echo -e "${BLUE}【Kernel Parameter Check】${NC}"

check_sysctl() {
    local param=$1
    local expected=$2
    local current=$(sysctl -n "$param" 2>/dev/null || echo "Not set")
    
    echo -n "  $param = $current ... "
    if [ "$current" = "$expected" ]; then
        echo -e "${GREEN}✅${NC}"
        PASS=$((PASS + 1))
    else
        echo -e "${YELLOW}⚠️  (recommended: $expected)${NC}"
        WARN=$((WARN + 1))
    fi
}

check_sysctl "net.ipv4.tcp_syncookies" "1"
check_sysctl "net.ipv4.tcp_max_syn_backlog" "8192"

echo ""

# ===== Group 3: Configuration File Check =====
echo -e "${BLUE}【Configuration File Check】${NC}"

test_check "Main Script Exists" "[ -f /usr/local/bin/syn_defense.sh ]"
test_check "Main Script Executable" "[ -x /usr/local/bin/syn_defense.sh ]"
test_check "Config Directory Exists" "[ -d /etc/syn_defense ]"
test_check "Whitelist Config Exists" "[ -f /etc/syn_defense/whitelist.conf ]"
test_check "Parameter Config Exists" "[ -f /etc/syn_defense/config.conf ]"

echo ""

# ===== Group 4: System Resource Check =====
echo -e "${BLUE}【System Resource Check】${NC}"

# Memory check
MEM_AVAILABLE=$(free -m | awk 'NR==2{print $7}')
echo -n "  Available Memory: ${MEM_AVAILABLE}MB ... "
if [ "$MEM_AVAILABLE" -gt 500 ]; then
    echo -e "${GREEN}✅${NC}"
    PASS=$((PASS + 1))
else
    echo -e "${YELLOW}⚠️  (recommended >500MB)${NC}"
    WARN=$((WARN + 1))
fi

# Disk space check
DISK_AVAILABLE=$(df /var/log | tail -1 | awk '{print $4}')
echo -n "  /var/log Available Space: ${DISK_AVAILABLE}KB ... "
if [ "$DISK_AVAILABLE" -gt 1048576 ]; then  # >1GB
    echo -e "${GREEN}✅${NC}"
    PASS=$((PASS + 1))
else
    echo -e "${YELLOW}⚠️  (recommended >1GB)${NC}"
    WARN=$((WARN + 1))
fi

echo ""

# ===== Group 5: Network Connection Test =====
echo -e "${BLUE}【Network Connection Test】${NC}"

# Check current connection count
CURRENT_CONN=$(ss -tan | wc -l)
echo "  Current TCP Connections: $CURRENT_CONN"

SYN_RECV=$(ss -tan state syn-recv 2>/dev/null | wc -l)
echo -n "  Current SYN_RECV Connections: $SYN_RECV ... "
if [ "$SYN_RECV" -lt 100 ]; then
    echo -e "${GREEN}✅ Normal${NC}"
    PASS=$((PASS + 1))
elif [ "$SYN_RECV" -lt 300 ]; then
    echo -e "${YELLOW}⚠️  Slightly High${NC}"
    WARN=$((WARN + 1))
else
    echo -e "${RED}❌ May Be Under Attack${NC}"
    FAIL=$((FAIL + 1))
fi

echo ""

# ===== Group 6: Defense Function Test =====
echo -e "${BLUE}【Defense Function Test】${NC}"

# Test ipset creation
echo -n "  Test ipset creation ... "
if ipset create test_syn_set hash:ip timeout 60 2>/dev/null; then
    ipset destroy test_syn_set 2>/dev/null
    echo -e "${GREEN}✅${NC}"
    PASS=$((PASS + 1))
else
    echo -e "${RED}❌${NC}"
    FAIL=$((FAIL + 1))
fi

# Test iptables rules
echo -n "  Test adding iptables rule ... "
if iptables -A INPUT -p tcp --dport 9999 -j ACCEPT -m comment --comment "test_syn_defense" 2>/dev/null; then
    iptables -D INPUT -p tcp --dport 9999 -j ACCEPT -m comment --comment "test_syn_defense" 2>/dev/null
    echo -e "${GREEN}✅${NC}"
    PASS=$((PASS + 1))
else
    echo -e "${RED}❌${NC}"
    FAIL=$((FAIL + 1))
fi

echo ""

# ===== Group 7: Service Status Check =====
echo -e "${BLUE}【Service Status Check】${NC}"

if systemctl list-unit-files | grep -q "syn-defense.service"; then
    echo -n "  Defense service installed ... ${GREEN}✅${NC}"
    echo ""
    
    if systemctl is-active --quiet syn-defense; then
        echo -e "  Defense service running ... ${GREEN}✅ Running${NC}"
        PASS=$((PASS + 1))
        
        # Check logs
        if [ -f /var/log/syn_defense.log ]; then
            LOG_LINES=$(wc -l < /var/log/syn_defense.log)
            echo "  Log file exists: $LOG_LINES lines"
            PASS=$((PASS + 1))
        else
            test_warn "Log file" "Does not exist"
        fi
    else
        echo -e "  Defense service status ... ${YELLOW}⚠️  Not Running${NC}"
        WARN=$((WARN + 1))
    fi
else
    test_warn "Defense service" "Not installed"
fi

echo ""

# ===== Group 8: Whitelist Function Test =====
echo -e "${BLUE}【Whitelist Function Test】${NC}"

if [ -f /etc/syn_defense/whitelist.conf ]; then
    WL_COUNT=$(grep -v '^#' /etc/syn_defense/whitelist.conf | grep -v '^$' | wc -l)
    echo "  Whitelist config entries: $WL_COUNT"
    
    if [ "$WL_COUNT" -gt 5 ]; then
        echo -e "  ${GREEN}✅ Whitelist config normal${NC}"
        PASS=$((PASS + 1))
    else
        test_warn "Whitelist" "Too few entries, recommend checking configuration"
    fi
else
    echo -e "  ${RED}❌ Whitelist config file does not exist${NC}"
    FAIL=$((FAIL + 1))
fi

echo ""

# ===== Summary =====
echo -e "${BLUE}=========================================="
echo -e "  Test Summary"
echo -e "==========================================${NC}"
echo ""
echo -e "  ${GREEN}✅ Passed: $PASS${NC}"
echo -e "  ${YELLOW}⚠️  Warnings: $WARN${NC}"
echo -e "  ${RED}❌ Failed: $FAIL${NC}"
echo ""

# Determine result
if [ "$FAIL" -eq 0 ]; then
    if [ "$WARN" -eq 0 ]; then
        echo -e "${GREEN}🎉 All tests passed! System is ready.${NC}"
        exit 0
    else
        echo -e "${YELLOW}⚠️  Warnings present, recommend review before deployment.${NC}"
        exit 0
    fi
else
    echo -e "${RED}❌ Failures present, please resolve issues before deployment.${NC}"
    exit 1
fi
