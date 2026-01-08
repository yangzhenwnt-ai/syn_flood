#!/bin/bash
# ===================================================
# SYN 防护系统 - 完全卸载脚本
# ===================================================

set -e

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

echo -e "${RED}=========================================="
echo -e "  🗑️  SYN 防护系统 - 完全卸载"
echo -e "==========================================${NC}"
echo ""
echo -e "${YELLOW}⚠️  警告：此操作将删除所有相关文件和配置！${NC}"
echo ""

# 确认操作
read -p "确认要完全卸载吗？(yes/no): " confirm

if [ "$confirm" != "yes" ]; then
    echo -e "${YELLOW}卸载已取消${NC}"
    exit 0
fi

echo ""
echo -e "${YELLOW}开始卸载...${NC}"
echo ""

# 检查权限
if [ "$EUID" -ne 0 ]; then
    echo -e "${RED}❌ 请使用 root 用户运行${NC}"
    exit 1
fi

# ===== 步骤1：停止并禁用服务 =====
echo -e "[1/8] 停止并禁用服务..."
if systemctl is-active --quiet syn-defense 2>/dev/null; then
    systemctl stop syn-defense
    echo -e "  ${GREEN}✅ 服务已停止${NC}"
else
    echo -e "  ${BLUE}ℹ️  服务未运行${NC}"
fi

if systemctl is-enabled --quiet syn-defense 2>/dev/null; then
    systemctl disable syn-defense >/dev/null 2>&1
    echo -e "  ${GREEN}✅ 开机自启已禁用${NC}"
else
    echo -e "  ${BLUE}ℹ️  服务未启用${NC}"
fi

# 强制杀死进程
pkill -f syn_defense.sh 2>/dev/null || true
echo -e "  ${GREEN}✅ 相关进程已清理${NC}"

# ===== 步骤2：删除 systemd 服务文件 =====
echo -e "[2/8] 删除 systemd 服务文件..."
if [ -f /etc/systemd/system/syn-defense.service ]; then
    rm -f /etc/systemd/system/syn-defense.service
    systemctl daemon-reload
    echo -e "  ${GREEN}✅ 服务文件已删除${NC}"
else
    echo -e "  ${BLUE}ℹ️  服务文件不存在${NC}"
fi

# ===== 步骤3：清除 iptables 规则 =====
echo -e "[3/8] 清除 iptables 规则..."

if iptables -C INPUT -m set --match-set syn_whitelist src -j ACCEPT 2>/dev/null; then
    iptables -D INPUT -m set --match-set syn_whitelist src -j ACCEPT
    echo -e "  ${GREEN}✅ 白名单规则已删除${NC}"
else
    echo -e "  ${BLUE}ℹ️  白名单规则不存在${NC}"
fi

if iptables -C INPUT -m set --match-set syn_blacklist src -j DROP 2>/dev/null; then
    iptables -D INPUT -m set --match-set syn_blacklist src -j DROP
    echo -e "  ${GREEN}✅ 黑名单规则已删除${NC}"
else
    echo -e "  ${BLUE}ℹ️  黑名单规则不存在${NC}"
fi

if iptables -C INPUT -p tcp --syn -m connlimit --connlimit-above 100 --connlimit-mask 32 -j DROP 2>/dev/null; then
    iptables -D INPUT -p tcp --syn -m connlimit --connlimit-above 100 --connlimit-mask 32 -j DROP
    echo -e "  ${GREEN}✅ 连接限制规则已删除${NC}"
else
    echo -e "  ${BLUE}ℹ️  连接限制规则不存在${NC}"
fi

# ===== 步骤4：删除 ipset =====
echo -e "[4/8] 删除 ipset..."

if ipset list syn_blacklist &>/dev/null; then
    ipset destroy syn_blacklist
    echo -e "  ${GREEN}✅ syn_blacklist 已删除${NC}"
else
    echo -e "  ${BLUE}ℹ️  syn_blacklist 不存在${NC}"
fi

if ipset list syn_whitelist &>/dev/null; then
    ipset destroy syn_whitelist
    echo -e "  ${GREEN}✅ syn_whitelist 已删除${NC}"
else
    echo -e "  ${BLUE}ℹ️  syn_whitelist 不存在${NC}"
fi

# ===== 步骤5：删除主脚本 =====
echo -e "[5/8] 删除主脚本..."
if [ -f /usr/local/bin/syn_defense.sh ]; then
    rm -f /usr/local/bin/syn_defense.sh
    echo -e "  ${GREEN}✅ 主脚本已删除${NC}"
else
    echo -e "  ${BLUE}ℹ️  主脚本不存在${NC}"
fi

# ===== 步骤6：删除配置文件 =====
echo -e "[6/8] 删除配置文件..."

# 先备份到临时目录（以防万一）
if [ -d /etc/syn_defense ]; then
    BACKUP_DIR="/tmp/syn_defense_backup_$(date +%Y%m%d_%H%M%S)"
    mkdir -p "$BACKUP_DIR"
    cp -r /etc/syn_defense/* "$BACKUP_DIR/" 2>/dev/null || true
    echo -e "  ${YELLOW}ℹ️  配置已备份到: $BACKUP_DIR${NC}"
    
    rm -rf /etc/syn_defense
    echo -e "  ${GREEN}✅ 配置目录已删除${NC}"
else
    echo -e "  ${BLUE}ℹ️  配置目录不存在${NC}"
fi

# ===== 步骤7：删除日志文件 =====
echo -e "[7/8] 删除日志文件..."
if [ -f /var/log/syn_defense.log ]; then
    # 备份日志
    if [ -n "$BACKUP_DIR" ]; then
        cp /var/log/syn_defense.log "$BACKUP_DIR/" 2>/dev/null || true
    fi
    
    rm -f /var/log/syn_defense.log
    echo -e "  ${GREEN}✅ 日志文件已删除${NC}"
else
    echo -e "  ${BLUE}ℹ️  日志文件不存在${NC}"
fi

# ===== 步骤8：删除内核参数配置 =====
echo -e "[8/8] 删除内核参数配置..."
if [ -f /etc/sysctl.d/99-syn-defense.conf ]; then
    rm -f /etc/sysctl.d/99-syn-defense.conf
    echo -e "  ${GREEN}✅ 内核参数配置已删除${NC}"
else
    echo -e "  ${BLUE}ℹ️  内核参数配置不存在${NC}"
fi

# 清理临时文件
rm -f /var/run/syn_defense.lock 2>/dev/null || true
rm -f /var/run/syn_defense.pid 2>/dev/null || true
rm -f /var/run/syn_whitelist.md5 2>/dev/null || true

# 记录卸载
logger -t syn_defense "系统已完全卸载于 $(date '+%Y-%m-%d %H:%M:%S')"

echo ""
echo -e "${GREEN}=========================================="
echo -e "  ✅ 卸载完成"
echo -e "==========================================${NC}"
echo ""

if [ -n "$BACKUP_DIR" ]; then
    echo -e "${YELLOW}📦 备份信息：${NC}"
    echo -e "  配置和日志已备份到: ${YELLOW}$BACKUP_DIR${NC}"
    echo -e "  如需恢复，可从备份目录复制"
    echo ""
fi

echo -e "${BLUE}📋 已删除的内容：${NC}"
echo "  ✅ systemd 服务文件"
echo "  ✅ 主脚本 (/usr/local/bin/syn_defense.sh)"
echo "  ✅ 配置目录 (/etc/syn_defense/)"
echo "  ✅ 日志文件 (/var/log/syn_defense.log)"
echo "  ✅ 内核参数配置"
echo "  ✅ iptables 规则"
echo "  ✅ ipset 集合"
echo ""

echo -e "${GREEN}🎉 SYN 防护系统已完全卸载！${NC}"
echo ""

