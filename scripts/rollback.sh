#!/bin/bash
# ===================================================
# SYN 防护系统 - 紧急回滚脚本
# ===================================================

set -e

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

echo -e "${RED}=========================================="
echo -e "  🚨 SYN 防护系统 - 紧急回滚"
echo -e "==========================================${NC}"
echo ""

# 确认操作
read -p "确认要执行回滚吗？这将停止防护服务并清除所有规则。(yes/no): " confirm

if [ "$confirm" != "yes" ]; then
    echo -e "${YELLOW}回滚已取消${NC}"
    exit 0
fi

echo ""
echo -e "${YELLOW}开始执行回滚...${NC}"
echo ""

# ===== 步骤1：停止服务 =====
echo -e "[1/6] 停止防护服务..."
if systemctl stop syn-defense 2>/dev/null; then
    echo -e "  ${GREEN}✅ 服务已停止${NC}"
else
    echo -e "  ${YELLOW}⚠️  服务未运行或停止失败${NC}"
fi

# 强制杀死进程
pkill -f syn_defense.sh 2>/dev/null || true
echo -e "  ${GREEN}✅ 相关进程已清理${NC}"

# ===== 步骤2：清空黑名单 =====
echo -e "[2/6] 清空黑名单..."
if ipset flush syn_blacklist 2>/dev/null; then
    echo -e "  ${GREEN}✅ IP黑名单已清空${NC}"
else
    echo -e "  ${YELLOW}⚠️  IP黑名单不存在或清空失败${NC}"
fi

if ipset flush syn_blacklist_subnet 2>/dev/null; then
    echo -e "  ${GREEN}✅ 网段黑名单已清空${NC}"
else
    echo -e "  ${YELLOW}⚠️  网段黑名单不存在或清空失败${NC}"
fi

# ===== 步骤3：删除 iptables 规则 =====
echo -e "[3/6] 删除 iptables 规则..."

# 删除白名单规则
if iptables -D INPUT -m set --match-set syn_whitelist src -j ACCEPT 2>/dev/null; then
    echo -e "  ${GREEN}✅ 白名单规则已删除${NC}"
else
    echo -e "  ${YELLOW}⚠️  白名单规则不存在${NC}"
fi

# 删除黑名单规则
if iptables -D INPUT -m set --match-set syn_blacklist src -j DROP 2>/dev/null; then
    echo -e "  ${GREEN}✅ IP黑名单规则已删除${NC}"
else
    echo -e "  ${YELLOW}⚠️  IP黑名单规则不存在${NC}"
fi

# 删除网段黑名单规则
if iptables -D INPUT -m set --match-set syn_blacklist_subnet src -j DROP 2>/dev/null; then
    echo -e "  ${GREEN}✅ 网段黑名单规则已删除${NC}"
else
    echo -e "  ${YELLOW}⚠️  网段黑名单规则不存在${NC}"
fi

# 删除连接限制规则
if iptables -D INPUT -p tcp --syn -m connlimit --connlimit-above 100 --connlimit-mask 32 -j DROP 2>/dev/null; then
    echo -e "  ${GREEN}✅ 连接限制规则已删除${NC}"
else
    echo -e "  ${YELLOW}⚠️  连接限制规则不存在${NC}"
fi

# ===== 步骤4：删除 ipset =====
echo -e "[4/6] 删除 ipset..."

if ipset destroy syn_blacklist 2>/dev/null; then
    echo -e "  ${GREEN}✅ syn_blacklist 已删除${NC}"
else
    echo -e "  ${YELLOW}⚠️  syn_blacklist 不存在${NC}"
fi

if ipset destroy syn_blacklist_subnet 2>/dev/null; then
    echo -e "  ${GREEN}✅ syn_blacklist_subnet 已删除${NC}"
else
    echo -e "  ${YELLOW}⚠️  syn_blacklist_subnet 不存在${NC}"
fi

if ipset destroy syn_whitelist 2>/dev/null; then
    echo -e "  ${GREEN}✅ syn_whitelist 已删除${NC}"
else
    echo -e "  ${YELLOW}⚠️  syn_whitelist 不存在${NC}"
fi

# ===== 步骤5：清理临时文件 =====
echo -e "[5/6] 清理临时文件..."
rm -f /var/run/syn_defense.lock 2>/dev/null || true
rm -f /var/run/syn_defense.pid 2>/dev/null || true
rm -f /var/run/syn_whitelist.md5 2>/dev/null || true
echo -e "  ${GREEN}✅ 临时文件已清理${NC}"

# ===== 步骤6：记录回滚 =====
echo -e "[6/6] 记录回滚..."
logger -t syn_defense "紧急回滚已执行于 $(date '+%Y-%m-%d %H:%M:%S')"

if [ -f /var/log/syn_defense.log ]; then
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] [ROLLBACK] 紧急回滚已执行" >> /var/log/syn_defense.log
fi

echo -e "  ${GREEN}✅ 已记录${NC}"

echo ""
echo -e "${GREEN}=========================================="
echo -e "  ✅ 回滚完成"
echo -e "==========================================${NC}"
echo ""
echo -e "${YELLOW}注意事项：${NC}"
echo "  1. 防护服务已完全停止"
echo "  2. 所有防护规则已清除"
echo "  3. 配置文件仍然保留在 /etc/syn_defense/"
echo "  4. 如需重新启动，执行: systemctl start syn-defense"
echo ""
echo -e "${YELLOW}如果需要完全卸载：${NC}"
echo "  1. 删除服务: systemctl disable syn-defense && rm /etc/systemd/system/syn-defense.service"
echo "  2. 删除脚本: rm /usr/local/bin/syn_defense.sh"
echo "  3. 删除配置: rm -rf /etc/syn_defense"
echo "  4. 删除日志: rm /var/log/syn_defense.log"
echo ""

