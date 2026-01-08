#!/bin/bash
# ===================================================
# SYN Defense Monitoring Script
# ===================================================

set -euo pipefail

# Color definitions
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

# Get statistics
get_stats() {
    local syn_recv=$(ss -tan state syn-recv 2>/dev/null | awk 'NR>1' | wc -l | tr -d ' ')
    
    # Fix: Use actual entry count under Members in ipset list
    local blacklist=$(ipset list syn_blacklist 2>/dev/null | awk '/^Members:$/,0 {if(/^[0-9]/) count++} END {print count+0}')
    local subnet_blacklist=$(ipset list syn_blacklist_subnet 2>/dev/null | awk '/^Members:$/,0 {if(/^[0-9]/) count++} END {print count+0}')
    local whitelist=$(ipset list syn_whitelist 2>/dev/null | awk '/^Members:$/,0 {if(/^[0-9]/) count++} END {print count+0}')
    
    local total_conn=$(ss -tan 2>/dev/null | awk 'NR>1' | wc -l | tr -d ' ')
    local established=$(ss -tan state established 2>/dev/null | awk 'NR>1' | wc -l | tr -d ' ')
    
    echo "$syn_recv $blacklist $subnet_blacklist $whitelist $total_conn $established"
}

# Get TOP attackers
get_top_attackers() {
    ss -tan state syn-recv 2>/dev/null | \
        awk 'NR>1 {print $4}' | \
        cut -d: -f1 | \
        sort | uniq -c | \
        sort -rn | \
        head -10
}

# Check IP status
check_ip_status() {
    local ip=$1
    local status=""
    
    if ipset test syn_blacklist "$ip" 2>/dev/null; then
        status="${RED}[Banned]${NC}"
    elif ipset test syn_whitelist "$ip" 2>/dev/null; then
        status="${GREEN}[Whitelisted]${NC}"
    else
        status="${YELLOW}[Unprocessed]${NC}"
    fi
    
    echo -e "$status"
}

# Show dashboard
show_dashboard() {
    clear
    
    # Read statistics
    read syn_recv blacklist subnet_blacklist whitelist total_conn established <<< $(get_stats)
    
    # Calculate status
    local status
    if [ "$syn_recv" -gt 500 ]; then
        status="${RED}⚠️  Severe Attack${NC}"
    elif [ "$syn_recv" -gt 200 ]; then
        status="${YELLOW}⚡ Moderate Attack${NC}"
    elif [ "$syn_recv" -gt 50 ]; then
        status="${YELLOW}⚠️  Light Attack${NC}"
    else
        status="${GREEN}✅ Normal${NC}"
    fi
    
    # Service status
    local service_status
    if systemctl is-active --quiet syn-defense 2>/dev/null; then
        service_status="${GREEN}Running${NC}"
    else
        service_status="${RED}Stopped${NC}"
    fi
    
    # Show header
    echo -e "${BLUE}╔═══════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${BLUE}║      SYN Defense System - Real-time Monitoring Dashboard     ║${NC}"
    echo -e "${BLUE}╚═══════════════════════════════════════════════════════════════╝${NC}"
    echo ""
    
    # System status
    echo -e "${CYAN}【System Status】${NC}"
    echo -e "  Current Status: $status"
    echo -e "  Service Status: $service_status"
    echo -e "  Update Time: $(date '+%Y-%m-%d %H:%M:%S')"
    echo ""
    
    # Connection statistics
    echo -e "${CYAN}【Connection Statistics】${NC}"
    printf "  %-20s: %6s\n" "SYN_RECV Connections" "$syn_recv"
    printf "  %-20s: %6s\n" "Established Connections" "$established"
    printf "  %-20s: %6s\n" "Total TCP Connections" "$total_conn"
    echo ""
    
    # Defense statistics
    echo -e "${CYAN}【Defense Statistics】${NC}"
    printf "  %-20s: %6s\n" "Blacklist IPs" "$blacklist"
    printf "  %-20s: %6s\n" "Blacklist Subnets" "$subnet_blacklist"
    printf "  %-20s: %6s\n" "Whitelist Entries" "$whitelist"
    echo ""
    
    # TOP 10 attack sources
    echo -e "${CYAN}【TOP 10 Attack Sources】${NC}"
    
    local count=0
    get_top_attackers | while read num ip; do
        count=$((count + 1))
        local status=$(check_ip_status "$ip")
        printf "  %2d. %15s x %-6s %s\n" "$count" "$ip" "$num" "$status"
    done
    
    # If no attacks
    if [ "$syn_recv" -lt 10 ]; then
        echo -e "  ${GREEN}No obvious attacks currently${NC}"
    fi
    
    echo ""
    
    # Recent logs
    echo -e "${CYAN}【Last 5 Log Entries】${NC}"
    if [ -f /var/log/syn_defense.log ]; then
        tail -n 5 /var/log/syn_defense.log 2>/dev/null | sed 's/^/  /' || echo -e "  ${YELLOW}No logs yet${NC}"
    else
        echo -e "  ${YELLOW}Log file does not exist${NC}"
    fi
    
    echo ""
    echo -e "${BLUE}═══════════════════════════════════════════════════════════════${NC}"
    echo -e "Press ${YELLOW}Ctrl+C${NC} to exit monitoring"
}

# Simple statistics mode
simple_stats() {
    read syn_recv blacklist subnet_blacklist whitelist total_conn established <<< $(get_stats)
    echo "SYN_RECV: $syn_recv, Blacklist: $blacklist, Subnet Blacklist: $subnet_blacklist, Whitelist: $whitelist, Total Connections: $total_conn"
}

# Detailed report
detailed_report() {
    echo -e "${BLUE}=========================================="
    echo -e "  SYN Defense System - Detailed Report"
    echo -e "==========================================${NC}"
    echo ""
    
    # Basic statistics
    read syn_recv blacklist subnet_blacklist whitelist total_conn established <<< $(get_stats)
    
    echo -e "${CYAN}【Connection Statistics】${NC}"
    echo "  SYN_RECV Connections:      $syn_recv"
    echo "  Established Connections:   $established"
    echo "  Total TCP Connections:     $total_conn"
    echo ""
    
    echo -e "${CYAN}【Defense Statistics】${NC}"
    echo "  Blacklist IPs:             $blacklist"
    echo "  Blacklist Subnets:         $subnet_blacklist"
    echo "  Whitelist Entries:         $whitelist"
    echo ""
    
    # Service status
    echo -e "${CYAN}【Service Status】${NC}"
    if systemctl is-active --quiet syn-defense 2>/dev/null; then
        echo -e "  Status: ${GREEN}Running${NC}"
        echo "  Uptime: $(systemctl show syn-defense -p ActiveEnterTimestamp --value | xargs -I{} date -d {} '+%Y-%m-%d %H:%M:%S' 2>/dev/null || echo 'Unknown')"
    else
        echo -e "  Status: ${RED}Stopped${NC}"
    fi
    echo ""
    
    # TOP 20 attack sources
    echo -e "${CYAN}【TOP 20 Attack Source Details】${NC}"
    echo "  Rank  IP Address       Conn.   Status"
    echo "  ----  --------------  ------  --------"
    
    local count=0
    get_top_attackers | head -20 | while read num ip; do
        count=$((count + 1))
        local status="Normal"
        if ipset test syn_blacklist "$ip" 2>/dev/null; then
            status="${RED}Banned${NC}"
        elif ipset test syn_whitelist "$ip" 2>/dev/null; then
            status="${GREEN}Whitelisted${NC}"
        fi
        printf "  %-4d  %-15s  %-6s  %s\n" "$count" "$ip" "$num" "$status"
    done
    
    echo ""
    
    # Blacklist details
    if [ "$blacklist" -gt 0 ]; then
        echo -e "${CYAN}【IP Blacklist Details (Last 10)】${NC}"
        ipset list syn_blacklist 2>/dev/null | grep "^[0-9]" | head -10 | while read line; do
            echo "  $line"
        done
        echo ""
    fi
    
    # Subnet blacklist details
    if [ "$subnet_blacklist" -gt 0 ]; then
        echo -e "${CYAN}【Subnet Blacklist (CIDR Blocks)】${NC}"
        ipset list syn_blacklist_subnet 2>/dev/null | grep "^[0-9]" | while read line; do
            echo "  $line"
        done
        echo ""
    fi
    
    # Log analysis
    if [ -f /var/log/syn_defense.log ]; then
        echo -e "${CYAN}【Today's Ban Statistics】${NC}"
        local today=$(date '+%Y-%m-%d')
        local today_blocks=$(grep "$today" /var/log/syn_defense.log 2>/dev/null | grep -c "Banned" || echo 0)
        echo "  Today's banned IPs:        $today_blocks"
        echo ""
        
        echo -e "${CYAN}【Last 10 Important Log Entries】${NC}"
        grep -E "ALERT|ERROR|WARN" /var/log/syn_defense.log 2>/dev/null | tail -10 | sed 's/^/  /' || echo "  No important logs yet"
    fi
    
    echo ""
}

# Main program
main() {
    case "${1:-watch}" in
        watch)
            # Real-time monitoring mode
            while true; do
                show_dashboard
                sleep 3
            done
            ;;
        stats)
            # Simple statistics
            simple_stats
            ;;
        report)
            # Detailed report
            detailed_report
            ;;
        top)
            # Show TOP attack IPs only
            echo "TOP 10 Attack Sources:"
            get_top_attackers | while read num ip; do
                local status=$(check_ip_status "$ip")
                echo "  $ip x $num $status"
            done
            ;;
        *)
            echo "Usage: $0 {watch|stats|report|top}"
            echo ""
            echo "  watch   - Real-time monitoring dashboard (default)"
            echo "  stats   - Simple statistics output"
            echo "  report  - Detailed report"
            echo "  top     - TOP attack IP list"
            exit 1
            ;;
    esac
}

main "$@"
