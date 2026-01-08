#!/bin/bash
# ===================================================
# SYN 防护系统 - 测试脚本
# ===================================================

set -euo pipefail

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

PASS=0
FAIL=0
WARN=0

# 测试函数
test_check() {
    local name="$1"
    local command="$2"
    local expected="${3:-0}"
    
    echo -n "  测试: $name ... "
    
    if eval "$command" >/dev/null 2>&1; then
        local result=$?
    else
        local result=$?
    fi
    
    if [ "$result" -eq "$expected" ]; then
        echo -e "${GREEN}✅ 通过${NC}"
        PASS=$((PASS + 1))
        return 0
    else
        echo -e "${RED}❌ 失败${NC}"
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
echo -e "  SYN 防护系统 - 环境测试"
echo -e "==========================================${NC}"
echo ""

# ===== 第一组：基础环境检查 =====
echo -e "${BLUE}【基础环境检查】${NC}"

test_check "Root 权限" "[ \$EUID -eq 0 ]"
test_check "ipset 已安装" "command -v ipset"
test_check "iptables 已安装" "command -v iptables"
test_check "ss 命令可用" "command -v ss"

if command -v systemctl &>/dev/null; then
    echo -e "  ${GREEN}✅ systemd 可用${NC}"
    PASS=$((PASS + 1))
else
    test_warn "systemd" "未安装或不可用，可能影响服务管理"
fi

echo ""

# ===== 第二组：内核参数检查 =====
echo -e "${BLUE}【内核参数检查】${NC}"

check_sysctl() {
    local param=$1
    local expected=$2
    local current=$(sysctl -n "$param" 2>/dev/null || echo "未设置")
    
    echo -n "  $param = $current ... "
    if [ "$current" = "$expected" ]; then
        echo -e "${GREEN}✅${NC}"
        PASS=$((PASS + 1))
    else
        echo -e "${YELLOW}⚠️  (建议值: $expected)${NC}"
        WARN=$((WARN + 1))
    fi
}

check_sysctl "net.ipv4.tcp_syncookies" "1"
check_sysctl "net.ipv4.tcp_max_syn_backlog" "8192"

echo ""

# ===== 第三组：配置文件检查 =====
echo -e "${BLUE}【配置文件检查】${NC}"

test_check "主脚本存在" "[ -f /usr/local/bin/syn_defense.sh ]"
test_check "主脚本可执行" "[ -x /usr/local/bin/syn_defense.sh ]"
test_check "配置目录存在" "[ -d /etc/syn_defense ]"
test_check "白名单配置存在" "[ -f /etc/syn_defense/whitelist.conf ]"
test_check "参数配置存在" "[ -f /etc/syn_defense/config.conf ]"

echo ""

# ===== 第四组：系统资源检查 =====
echo -e "${BLUE}【系统资源检查】${NC}"

# 内存检查
MEM_AVAILABLE=$(free -m | awk 'NR==2{print $7}')
echo -n "  可用内存: ${MEM_AVAILABLE}MB ... "
if [ "$MEM_AVAILABLE" -gt 500 ]; then
    echo -e "${GREEN}✅${NC}"
    PASS=$((PASS + 1))
else
    echo -e "${YELLOW}⚠️  (建议 >500MB)${NC}"
    WARN=$((WARN + 1))
fi

# 磁盘空间检查
DISK_AVAILABLE=$(df /var/log | tail -1 | awk '{print $4}')
echo -n "  /var/log 可用空间: ${DISK_AVAILABLE}KB ... "
if [ "$DISK_AVAILABLE" -gt 1048576 ]; then  # >1GB
    echo -e "${GREEN}✅${NC}"
    PASS=$((PASS + 1))
else
    echo -e "${YELLOW}⚠️  (建议 >1GB)${NC}"
    WARN=$((WARN + 1))
fi

echo ""

# ===== 第五组：网络连接测试 =====
echo -e "${BLUE}【网络连接测试】${NC}"

# 检查当前连接数
CURRENT_CONN=$(ss -tan | wc -l)
echo "  当前 TCP 连接数: $CURRENT_CONN"

SYN_RECV=$(ss -tan state syn-recv 2>/dev/null | wc -l)
echo -n "  当前 SYN_RECV 连接数: $SYN_RECV ... "
if [ "$SYN_RECV" -lt 100 ]; then
    echo -e "${GREEN}✅ 正常${NC}"
    PASS=$((PASS + 1))
elif [ "$SYN_RECV" -lt 300 ]; then
    echo -e "${YELLOW}⚠️  偏高${NC}"
    WARN=$((WARN + 1))
else
    echo -e "${RED}❌ 可能正在遭受攻击${NC}"
    FAIL=$((FAIL + 1))
fi

echo ""

# ===== 第六组：防护功能测试 =====
echo -e "${BLUE}【防护功能测试】${NC}"

# 测试 ipset 创建
echo -n "  测试创建 ipset ... "
if ipset create test_syn_set hash:ip timeout 60 2>/dev/null; then
    ipset destroy test_syn_set 2>/dev/null
    echo -e "${GREEN}✅${NC}"
    PASS=$((PASS + 1))
else
    echo -e "${RED}❌${NC}"
    FAIL=$((FAIL + 1))
fi

# 测试 iptables 规则
echo -n "  测试添加 iptables 规则 ... "
if iptables -A INPUT -p tcp --dport 9999 -j ACCEPT -m comment --comment "test_syn_defense" 2>/dev/null; then
    iptables -D INPUT -p tcp --dport 9999 -j ACCEPT -m comment --comment "test_syn_defense" 2>/dev/null
    echo -e "${GREEN}✅${NC}"
    PASS=$((PASS + 1))
else
    echo -e "${RED}❌${NC}"
    FAIL=$((FAIL + 1))
fi

echo ""

# ===== 第七组：服务状态检查 =====
echo -e "${BLUE}【服务状态检查】${NC}"

if systemctl list-unit-files | grep -q "syn-defense.service"; then
    echo -n "  防护服务已安装 ... ${GREEN}✅${NC}"
    echo ""
    
    if systemctl is-active --quiet syn-defense; then
        echo -e "  防护服务运行中 ... ${GREEN}✅ 运行中${NC}"
        PASS=$((PASS + 1))
        
        # 检查日志
        if [ -f /var/log/syn_defense.log ]; then
            LOG_LINES=$(wc -l < /var/log/syn_defense.log)
            echo "  日志文件存在: $LOG_LINES 行"
            PASS=$((PASS + 1))
        else
            test_warn "日志文件" "不存在"
        fi
    else
        echo -e "  防护服务状态 ... ${YELLOW}⚠️  未运行${NC}"
        WARN=$((WARN + 1))
    fi
else
    test_warn "防护服务" "未安装"
fi

echo ""

# ===== 第八组：白名单测试 =====
echo -e "${BLUE}【白名单功能测试】${NC}"

if [ -f /etc/syn_defense/whitelist.conf ]; then
    WL_COUNT=$(grep -v '^#' /etc/syn_defense/whitelist.conf | grep -v '^$' | wc -l)
    echo "  白名单配置条目数: $WL_COUNT"
    
    if [ "$WL_COUNT" -gt 5 ]; then
        echo -e "  ${GREEN}✅ 白名单配置正常${NC}"
        PASS=$((PASS + 1))
    else
        test_warn "白名单" "条目数过少，建议检查配置"
    fi
else
    echo -e "  ${RED}❌ 白名单配置文件不存在${NC}"
    FAIL=$((FAIL + 1))
fi

echo ""

# ===== 汇总 =====
echo -e "${BLUE}=========================================="
echo -e "  测试汇总"
echo -e "==========================================${NC}"
echo ""
echo -e "  ${GREEN}✅ 通过: $PASS${NC}"
echo -e "  ${YELLOW}⚠️  警告: $WARN${NC}"
echo -e "  ${RED}❌ 失败: $FAIL${NC}"
echo ""

# 判断结果
if [ "$FAIL" -eq 0 ]; then
    if [ "$WARN" -eq 0 ]; then
        echo -e "${GREEN}🎉 所有测试通过！系统已准备就绪。${NC}"
        exit 0
    else
        echo -e "${YELLOW}⚠️  存在警告项，建议检查后再部署。${NC}"
        exit 0
    fi
else
    echo -e "${RED}❌ 存在失败项，请解决问题后再部署。${NC}"
    exit 1
fi

