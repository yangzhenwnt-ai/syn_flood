#!/bin/bash
# ===================================================
# SYN 防护监控脚本
# ===================================================

set -euo pipefail

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

# 获取统计信息
get_stats() {
    local syn_recv=$(ss -tan state syn-recv 2>/dev/null | awk 'NR>1' | wc -l | tr -d ' ')
    
    # 修复：使用 ipset list 的 Members 下面的实际条目数
    local blacklist=$(ipset list syn_blacklist 2>/dev/null | awk '/^Members:$/,0 {if(/^[0-9]/) count++} END {print count+0}')
    local subnet_blacklist=$(ipset list syn_blacklist_subnet 2>/dev/null | awk '/^Members:$/,0 {if(/^[0-9]/) count++} END {print count+0}')
    local whitelist=$(ipset list syn_whitelist 2>/dev/null | awk '/^Members:$/,0 {if(/^[0-9]/) count++} END {print count+0}')
    
    local total_conn=$(ss -tan 2>/dev/null | awk 'NR>1' | wc -l | tr -d ' ')
    local established=$(ss -tan state established 2>/dev/null | awk 'NR>1' | wc -l | tr -d ' ')
    
    echo "$syn_recv $blacklist $subnet_blacklist $whitelist $total_conn $established"
}

# 获取TOP攻击IP
get_top_attackers() {
    ss -tan state syn-recv 2>/dev/null | \
        awk 'NR>1 {print $4}' | \
        cut -d: -f1 | \
        sort | uniq -c | \
        sort -rn | \
        head -10
}

# 检查IP状态
check_ip_status() {
    local ip=$1
    local status=""
    
    if ipset test syn_blacklist "$ip" 2>/dev/null; then
        status="${RED}[已封禁]${NC}"
    elif ipset test syn_whitelist "$ip" 2>/dev/null; then
        status="${GREEN}[白名单]${NC}"
    else
        status="${YELLOW}[未处理]${NC}"
    fi
    
    echo -e "$status"
}

# 显示仪表盘
show_dashboard() {
    clear
    
    # 读取统计数据
    read syn_recv blacklist subnet_blacklist whitelist total_conn established <<< $(get_stats)
    
    # 计算状态
    local status
    if [ "$syn_recv" -gt 500 ]; then
        status="${RED}⚠️  严重攻击${NC}"
    elif [ "$syn_recv" -gt 200 ]; then
        status="${YELLOW}⚡ 中等攻击${NC}"
    elif [ "$syn_recv" -gt 50 ]; then
        status="${YELLOW}⚠️  轻微攻击${NC}"
    else
        status="${GREEN}✅ 正常${NC}"
    fi
    
    # 服务状态
    local service_status
    if systemctl is-active --quiet syn-defense 2>/dev/null; then
        service_status="${GREEN}运行中${NC}"
    else
        service_status="${RED}已停止${NC}"
    fi
    
    # 显示头部
    echo -e "${BLUE}╔═══════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${BLUE}║           SYN 防护系统 - 实时监控仪表盘                      ║${NC}"
    echo -e "${BLUE}╚═══════════════════════════════════════════════════════════════╝${NC}"
    echo ""
    
    # 系统状态
    echo -e "${CYAN}【系统状态】${NC}"
    echo -e "  当前状态: $status"
    echo -e "  服务状态: $service_status"
    echo -e "  更新时间: $(date '+%Y-%m-%d %H:%M:%S')"
    echo ""
    
    # 连接统计
    echo -e "${CYAN}【连接统计】${NC}"
    printf "  %-20s: %6s\n" "SYN_RECV 连接数" "$syn_recv"
    printf "  %-20s: %6s\n" "已建立连接数" "$established"
    printf "  %-20s: %6s\n" "总 TCP 连接数" "$total_conn"
    echo ""
    
    # 防护统计
    echo -e "${CYAN}【防护统计】${NC}"
    printf "  %-20s: %6s\n" "黑名单 IP 数" "$blacklist"
    printf "  %-20s: %6s\n" "黑名单网段数" "$subnet_blacklist"
    printf "  %-20s: %6s\n" "白名单条目数" "$whitelist"
    echo ""
    
    # TOP 10 攻击IP
    echo -e "${CYAN}【TOP 10 攻击源】${NC}"
    
    local count=0
    get_top_attackers | while read num ip; do
        count=$((count + 1))
        local status=$(check_ip_status "$ip")
        printf "  %2d. %15s x %-6s %s\n" "$count" "$ip" "$num" "$status"
    done
    
    # 如果没有攻击
    if [ "$syn_recv" -lt 10 ]; then
        echo -e "  ${GREEN}当前无明显攻击${NC}"
    fi
    
    echo ""
    
    # 最近日志
    echo -e "${CYAN}【最近 5 条日志】${NC}"
    if [ -f /var/log/syn_defense.log ]; then
        tail -n 5 /var/log/syn_defense.log 2>/dev/null | sed 's/^/  /' || echo -e "  ${YELLOW}暂无日志${NC}"
    else
        echo -e "  ${YELLOW}日志文件不存在${NC}"
    fi
    
    echo ""
    echo -e "${BLUE}═══════════════════════════════════════════════════════════════${NC}"
    echo -e "按 ${YELLOW}Ctrl+C${NC} 退出监控"
}

# 简单统计模式
simple_stats() {
    read syn_recv blacklist subnet_blacklist whitelist total_conn established <<< $(get_stats)
    echo "SYN_RECV: $syn_recv, 黑名单: $blacklist, 网段黑名单: $subnet_blacklist, 白名单: $whitelist, 总连接: $total_conn"
}

# 详细报告
detailed_report() {
    echo -e "${BLUE}=========================================="
    echo -e "  SYN 防护系统 - 详细报告"
    echo -e "==========================================${NC}"
    echo ""
    
    # 基础统计
    read syn_recv blacklist subnet_blacklist whitelist total_conn established <<< $(get_stats)
    
    echo -e "${CYAN}【连接统计】${NC}"
    echo "  SYN_RECV 连接数:      $syn_recv"
    echo "  已建立连接数:         $established"
    echo "  总 TCP 连接数:        $total_conn"
    echo ""
    
    echo -e "${CYAN}【防护统计】${NC}"
    echo "  黑名单 IP 数:         $blacklist"
    echo "  黑名单网段数:         $subnet_blacklist"
    echo "  白名单条目数:         $whitelist"
    echo ""
    
    # 服务状态
    echo -e "${CYAN}【服务状态】${NC}"
    if systemctl is-active --quiet syn-defense 2>/dev/null; then
        echo -e "  状态: ${GREEN}运行中${NC}"
        echo "  运行时长: $(systemctl show syn-defense -p ActiveEnterTimestamp --value | xargs -I{} date -d {} '+%Y-%m-%d %H:%M:%S' 2>/dev/null || echo '未知')"
    else
        echo -e "  状态: ${RED}已停止${NC}"
    fi
    echo ""
    
    # TOP 20 攻击IP
    echo -e "${CYAN}【TOP 20 攻击源详情】${NC}"
    echo "  排名  IP地址           连接数  状态"
    echo "  ----  --------------  ------  --------"
    
    local count=0
    get_top_attackers | head -20 | while read num ip; do
        count=$((count + 1))
        local status="正常"
        if ipset test syn_blacklist "$ip" 2>/dev/null; then
            status="${RED}已封禁${NC}"
        elif ipset test syn_whitelist "$ip" 2>/dev/null; then
            status="${GREEN}白名单${NC}"
        fi
        printf "  %-4d  %-15s  %-6s  %s\n" "$count" "$ip" "$num" "$status"
    done
    
    echo ""
    
    # 黑名单详情
    if [ "$blacklist" -gt 0 ]; then
        echo -e "${CYAN}【IP黑名单详情（最近10条）】${NC}"
        ipset list syn_blacklist 2>/dev/null | grep "^[0-9]" | head -10 | while read line; do
            echo "  $line"
        done
        echo ""
    fi
    
    # 网段黑名单详情
    if [ "$subnet_blacklist" -gt 0 ]; then
        echo -e "${CYAN}【网段黑名单（CIDR封禁）】${NC}"
        ipset list syn_blacklist_subnet 2>/dev/null | grep "^[0-9]" | while read line; do
            echo "  $line"
        done
        echo ""
    fi
    
    # 日志分析
    if [ -f /var/log/syn_defense.log ]; then
        echo -e "${CYAN}【今日封禁统计】${NC}"
        local today=$(date '+%Y-%m-%d')
        local today_blocks=$(grep "$today" /var/log/syn_defense.log 2>/dev/null | grep -c "封禁" || echo 0)
        echo "  今日封禁 IP 数:       $today_blocks"
        echo ""
        
        echo -e "${CYAN}【最近 10 条重要日志】${NC}"
        grep -E "ALERT|ERROR|WARN" /var/log/syn_defense.log 2>/dev/null | tail -10 | sed 's/^/  /' || echo "  暂无重要日志"
    fi
    
    echo ""
}

# 主程序
main() {
    case "${1:-watch}" in
        watch)
            # 实时监控模式
            while true; do
                show_dashboard
                sleep 3
            done
            ;;
        stats)
            # 简单统计
            simple_stats
            ;;
        report)
            # 详细报告
            detailed_report
            ;;
        top)
            # 仅显示TOP攻击IP
            echo "TOP 10 攻击源："
            get_top_attackers | while read num ip; do
                local status=$(check_ip_status "$ip")
                echo "  $ip x $num $status"
            done
            ;;
        *)
            echo "用法: $0 {watch|stats|report|top}"
            echo ""
            echo "  watch   - 实时监控仪表盘（默认）"
            echo "  stats   - 简单统计输出"
            echo "  report  - 详细报告"
            echo "  top     - TOP攻击IP列表"
            exit 1
            ;;
    esac
}

main "$@"

