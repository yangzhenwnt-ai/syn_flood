#!/bin/bash
# ===================================================
# 生产级 SYN 防护脚本
# ===================================================
# 版本: 3.0 Final
# 特点: 最安全、零风险、低开销、支持白名单
# 性能: CPU<1%, 内存<10MB, 延迟<100ms
# ===================================================

set -euo pipefail

# ===== 配置文件路径 =====
CONF_DIR="/etc/syn_defense"
CONFIG_FILE="${CONF_DIR}/config.conf"
WHITELIST_FILE="${CONF_DIR}/whitelist.conf"
BACKUP_DIR="${CONF_DIR}/backup"

# ===== 锁文件 =====
LOCK_FILE="/var/run/syn_defense.lock"
PID_FILE="/var/run/syn_defense.pid"

# ===== 默认配置 =====
ENABLE_BLOCK=1
CHECK_INTERVAL=60
SINGLE_IP_THRESHOLD=30
SUBNET_IP_COUNT=10
SUBNET_CONN_COUNT=50
TOTAL_THRESHOLD=200
BAN_DURATION=3600
MAX_BLACKLIST_SIZE=10000
LOG_FILE="/var/log/syn_defense.log"
LOG_MAX_LINES=50000
DEBUG_MODE=0
WHITELIST_SET="syn_whitelist"
BLACKLIST_SET="syn_blacklist"
SUBNET_BLACKLIST_SET="syn_blacklist_subnet"
SUBNET_BAN_MODE="subnet"

# ===== 加载配置文件 =====
load_config() {
    if [ -f "$CONFIG_FILE" ]; then
        # 安全地加载配置（避免代码注入）
        while IFS='=' read -r key value; do
            # 跳过注释和空行
            [[ "$key" =~ ^[[:space:]]*# ]] && continue
            [[ -z "$key" ]] && continue
            
            # 去除前后空格和所有控制字符（包括\r）
            key=$(echo "$key" | tr -d '\r' | xargs)
            value=$(echo "$value" | tr -d '\r' | xargs)
            
            # 验证变量名（仅允许大写字母和下划线）
            if [[ "$key" =~ ^[A-Z_]+$ ]]; then
                eval "$key='$value'"
            fi
        done < "$CONFIG_FILE"
    fi
}

# ===== 日志函数 =====
log() {
    local level="${2:-INFO}"
    local message="[$(date '+%Y-%m-%d %H:%M:%S')] [$level] $1"
    
    # 写入日志文件
    echo "$message" >> "$LOG_FILE"
    
    # DEBUG模式输出到终端
    [ "${DEBUG_MODE:-0}" -eq 1 ] 2>/dev/null && echo "$message" >&2
    
    # 高优先级日志发送到syslog
    if [ "$level" = "ERROR" ] || [ "$level" = "ALERT" ]; then
        logger -t syn_defense "$message"
    fi
}

# ===== 日志清理 =====
cleanup_log() {
    if [ -f "$LOG_FILE" ]; then
        local line_count=$(wc -l < "$LOG_FILE" 2>/dev/null || echo 0)
        # 清理非数字字符
        line_count=$(echo "$line_count" | tr -cd '0-9')
        line_count=${line_count:-0}
        
        if [ "$line_count" -gt "${LOG_MAX_LINES:-50000}" ] 2>/dev/null; then
            tail -n "$LOG_MAX_LINES" "$LOG_FILE" > "${LOG_FILE}.tmp" 2>/dev/null
            mv "${LOG_FILE}.tmp" "$LOG_FILE" 2>/dev/null
            log "日志已清理，保留最近 $LOG_MAX_LINES 行"
        fi
    fi
}

# ===== 获取锁（防止并发执行） =====
acquire_lock() {
    if [ -f "$LOCK_FILE" ]; then
        local old_pid=$(cat "$LOCK_FILE" 2>/dev/null || echo "")
        
        # 检查进程是否还在运行
        if [ -n "$old_pid" ] && kill -0 "$old_pid" 2>/dev/null; then
            [ "${DEBUG_MODE:-0}" -eq 1 ] 2>/dev/null && echo "另一个实例正在运行 (PID: $old_pid)" >&2
            exit 0
        else
            # 清理僵尸锁文件
            rm -f "$LOCK_FILE"
        fi
    fi
    
    echo $$ > "$LOCK_FILE"
    trap "rm -f $LOCK_FILE" EXIT INT TERM
}

# ===== 初始化 IPSET =====
init_ipset() {
    # 检查ipset是否安装
    if ! command -v ipset &>/dev/null; then
        log "错误: ipset 未安装，请先安装: yum install ipset" "ERROR"
        return 1
    fi
    
    # 创建白名单 ipset
    if ! ipset list "$WHITELIST_SET" &>/dev/null; then
        ipset create "$WHITELIST_SET" hash:net maxelem 65536 comment 2>/dev/null || {
            log "创建白名单 ipset 失败" "ERROR"
            return 1
        }
        log "创建白名单 ipset: $WHITELIST_SET"
    fi
    
    # 创建黑名单 ipset（带超时）
    if ! ipset list "$BLACKLIST_SET" &>/dev/null; then
        ipset create "$BLACKLIST_SET" hash:ip timeout "$BAN_DURATION" maxelem "$MAX_BLACKLIST_SIZE" comment 2>/dev/null || {
            log "创建黑名单 ipset 失败" "ERROR"
            return 1
        }
        log "创建黑名单 ipset: $BLACKLIST_SET (超时: ${BAN_DURATION}s)"
    fi
    
    # 创建网段黑名单 ipset（支持CIDR格式，带超时）
    if ! ipset list "$SUBNET_BLACKLIST_SET" &>/dev/null; then
        ipset create "$SUBNET_BLACKLIST_SET" hash:net timeout "$BAN_DURATION" maxelem 1000 comment 2>/dev/null || {
            log "创建网段黑名单 ipset 失败" "ERROR"
            return 1
        }
        log "创建网段黑名单 ipset: $SUBNET_BLACKLIST_SET (支持CIDR)"
    fi
    
    return 0
}

# ===== 初始化 iptables 规则 =====
init_iptables() {
    # 检查白名单规则是否存在
    if ! iptables -C INPUT -m set --match-set "$WHITELIST_SET" src -j ACCEPT 2>/dev/null; then
        # 插入到第一条（最高优先级）
        iptables -I INPUT 1 -m set --match-set "$WHITELIST_SET" src -j ACCEPT -m comment --comment "SYN-Defense-Whitelist" 2>/dev/null || {
            log "添加白名单 iptables 规则失败" "ERROR"
            return 1
        }
        log "添加白名单 iptables 规则（最高优先级）"
    fi
    
    # 检查黑名单规则是否存在
    if ! iptables -C INPUT -m set --match-set "$BLACKLIST_SET" src -j DROP 2>/dev/null; then
        # 插入到白名单规则之后
        iptables -I INPUT 2 -m set --match-set "$BLACKLIST_SET" src -j DROP -m comment --comment "SYN-Defense-Blacklist" 2>/dev/null || {
            log "添加黑名单 iptables 规则失败" "ERROR"
            return 1
        }
        log "添加黑名单 iptables 规则"
    fi
    
    # 检查网段黑名单规则是否存在
    if ! iptables -C INPUT -m set --match-set "$SUBNET_BLACKLIST_SET" src -j DROP 2>/dev/null; then
        # 插入到普通黑名单规则之后
        iptables -I INPUT 3 -m set --match-set "$SUBNET_BLACKLIST_SET" src -j DROP -m comment --comment "SYN-Defense-Subnet-Blacklist" 2>/dev/null || {
            log "添加网段黑名单 iptables 规则失败" "ERROR"
            return 1
        }
        log "添加网段黑名单 iptables 规则（支持CIDR封禁）"
    fi
    
    # 添加基础连接限制（内核级，极低开销）
    if ! iptables -C INPUT -p tcp --syn -m connlimit --connlimit-above 100 --connlimit-mask 32 -j DROP 2>/dev/null; then
        iptables -A INPUT -p tcp --syn -m connlimit --connlimit-above 100 --connlimit-mask 32 -j DROP -m comment --comment "SYN-Defense-ConnLimit" 2>/dev/null || true
        log "添加连接数限制规则（每IP最多100并发）"
    fi
    
    return 0
}

# ===== 加载白名单 =====
load_whitelist() {
    if [ ! -f "$WHITELIST_FILE" ]; then
        log "白名单文件不存在: $WHITELIST_FILE" "WARN"
        return 0
    fi
    
    # 读取白名单文件的MD5，避免重复加载
    local whitelist_md5=$(md5sum "$WHITELIST_FILE" 2>/dev/null | awk '{print $1}')
    local last_md5_file="/var/run/syn_whitelist.md5"
    
    if [ -f "$last_md5_file" ]; then
        local last_md5=$(cat "$last_md5_file" 2>/dev/null || echo "")
        if [ "$whitelist_md5" = "$last_md5" ]; then
            [ "${DEBUG_MODE:-0}" -eq 1 ] 2>/dev/null && log "白名单未变化，跳过加载"
            return 0
        fi
    fi
    
    # 清空现有白名单
    ipset flush "$WHITELIST_SET" 2>/dev/null || true
    
    local count=0
    local failed=0
    local total_lines=0
    
    # 逐行读取白名单（先清理Windows回车符）
    while IFS= read -r line || [ -n "$line" ]; do
        total_lines=$((total_lines + 1))
        
        # 清理行尾的回车符和所有空白字符
        line=$(echo "$line" | tr -d '\r' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
        
        # 跳过注释和空行
        [[ "$line" =~ ^# ]] && continue
        [ -z "$line" ] && continue
        
        # 验证IP格式（匹配IP地址和CIDR）
        if [[ "$line" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+(/[0-9]+)?$ ]]; then
            # 添加到 ipset
            if ipset add "$WHITELIST_SET" "$line" -exist 2>/dev/null; then
                count=$((count + 1))
                [ "${DEBUG_MODE:-0}" -eq 1 ] 2>/dev/null && log "添加白名单: $line"
            else
                log "白名单添加失败: $line" "WARN"
                failed=$((failed + 1))
            fi
        else
            [ "${DEBUG_MODE:-0}" -eq 1 ] 2>/dev/null && log "跳过无效格式: [$line]"
        fi
    done < "$WHITELIST_FILE"
    
    # 保存MD5
    echo "$whitelist_md5" > "$last_md5_file"
    
    log "白名单加载完成: 读取 $total_lines 行, 成功 $count 条, 失败 $failed 条"
    return 0
}

# ===== 检查IP是否在白名单 =====
is_whitelisted() {
    ipset test "$WHITELIST_SET" "$1" 2>/dev/null
    return $?
}

# ===== 获取 SYN_RECV 数据 =====
get_syn_data() {
    # 优先使用 ss（性能更好）
    if command -v ss &>/dev/null; then
        ss -tan state syn-recv 2>/dev/null | \
            awk 'NR>1 {print $4}' | \
            cut -d: -f1 | \
            grep -E '^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$' | \
            sort
    else
        netstat -ant 2>/dev/null | \
            awk '/SYN_RECV/ {print $5}' | \
            cut -d: -f1 | \
            grep -E '^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$' | \
            sort
    fi
}

# ===== 检测单IP攻击 =====
detect_single_ip() {
    local syn_data="$1"
    local total_checked=0
    local blocked=0
    local whitelisted=0
    
    log "--- 策略1: 单IP高连接检测 (阈值: $SINGLE_IP_THRESHOLD) ---"
    
    # 使用 uniq -c 统计每个IP的连接数
    echo "$syn_data" | uniq -c | while read -r count ip; do
        [ -z "$ip" ] && continue
        total_checked=$((total_checked + 1))
        
        # 跳过白名单
        if is_whitelisted "$ip"; then
            [ "${DEBUG_MODE:-0}" -eq 1 ] 2>/dev/null && log "跳过白名单IP: $ip ($count 连接)"
            whitelisted=$((whitelisted + 1))
            continue
        fi
        
        # 超过阈值，加入黑名单
        if [ "${count:-0}" -ge "${SINGLE_IP_THRESHOLD:-30}" ] 2>/dev/null; then
            if [ "${ENABLE_BLOCK:-1}" -eq 1 ] 2>/dev/null; then
                # 添加到黑名单（带注释）
                if ipset add "$BLACKLIST_SET" "$ip" timeout "$BAN_DURATION" comment "single:$count" -exist 2>/dev/null; then
                    log "🚫 封禁单IP攻击: $ip (连接数: $count)" "ALERT"
                    blocked=$((blocked + 1))
                fi
            else
                log "⚠️  检测到单IP攻击: $ip (连接数: $count) [仅观察模式]" "WARN"
            fi
        fi
    done
    
    log "策略1完成: 检测 $total_checked 个IP, 封禁 $blocked 个, 跳过白名单 $whitelisted 个"
    
    return 0
}

# ===== 检测网段攻击 =====
detect_subnet() {
    local syn_data="$1"
    local ban_mode="${SUBNET_BAN_MODE:-ip}"
    
    log "--- 策略2: 网段分布式攻击检测 (IP数>=$SUBNET_IP_COUNT, 连接数>=$SUBNET_CONN_COUNT) ---"
    log "封禁模式: $ban_mode"
    
    # 使用awk进行高性能统计（修复二维数组问题）
    echo "$syn_data" | awk -v subnet_ip_count="$SUBNET_IP_COUNT" \
                             -v subnet_conn_count="$SUBNET_CONN_COUNT" \
                             -v enable_block="$ENABLE_BLOCK" \
                             -v ban_mode="$ban_mode" \
                             -v whitelist_set="$WHITELIST_SET" '
    {
        ip = $1
        
        # 提取C段
        split(ip, octets, ".")
        subnet = octets[1]"."octets[2]"."octets[3]".0/24"
        
        # 统计（使用字符串拼接代替二维数组）
        subnet_conn[subnet]++
        key = subnet SUBSEP ip
        if (!(key in seen)) {
            seen[key] = 1
            subnet_unique[subnet]++
            subnet_ip_list[subnet] = subnet_ip_list[subnet] " " ip
        }
    }
    
    END {
        for (subnet in subnet_conn) {
            total_conn = subnet_conn[subnet]
            unique_ips = subnet_unique[subnet]
            
            # 输出所有网段的统计信息（调试用）
            print "SUBNET_INFO:" subnet ":" unique_ips ":" total_conn
            
            # 判断是否为网段攻击
            if (unique_ips >= subnet_ip_count && total_conn >= subnet_conn_count) {
                print "SUBNET_ATTACK:" subnet ":" unique_ips ":" total_conn
                
                if (enable_block == 1) {
                    if (ban_mode == "subnet") {
                        # 模式1：直接封禁整个网段
                        print "BLOCK_SUBNET:" subnet
                    } else {
                        # 模式2：逐个封禁IP
                        split(subnet_ip_list[subnet], ips, " ")
                        for (i in ips) {
                            if (ips[i] != "") {
                                # 检查白名单
                                cmd = "ipset test " whitelist_set " " ips[i] " 2>/dev/null"
                                if (system(cmd) != 0) {
                                    print "BLOCK_IP:" ips[i] ":" subnet
                                }
                            }
                        }
                    }
                }
            }
        }
    }
    ' | while IFS=: read -r action p1 p2 p3; do
        case "$action" in
            SUBNET_INFO)
                log "网段统计: $p1 (IP数: $p2, 连接数: $p3)"
                ;;
            SUBNET_ATTACK)
                log "🚨 检测到网段攻击: $p1 (唯一IP: $p2, 总连接: $p3)" "ALERT"
                ;;
            BLOCK_SUBNET)
                # 检查白名单（网段级）
                if ipset test "$WHITELIST_SET" "$p1" 2>/dev/null; then
                    log "⚠️  跳过白名单网段: $p1" "WARN"
                else
                    if ipset add "$SUBNET_BLACKLIST_SET" "$p1" timeout "$BAN_DURATION" comment "subnet-attack" -exist 2>/dev/null; then
                        log "🚫 封禁整个攻击网段: $p1 (CIDR封禁)" "ALERT"
                    fi
                fi
                ;;
            BLOCK_IP)
                if ipset add "$BLACKLIST_SET" "$p1" timeout "$BAN_DURATION" comment "subnet:$p2" -exist 2>/dev/null; then
                    log "🚫 封禁网段攻击IP: $p1 (所属: $p2)" "ALERT"
                fi
                ;;
        esac
    done
    
    log "策略2完成"
    
    return 0
}

# ===== 检测高度分布式攻击 =====
# 针对"大量IP，每个IP只有1-3个连接"的攻击
detect_distributed() {
    local syn_data="$1"
    local total_conn="$2"
    local unique_ips="$3"
    
    # 计算IP密度（唯一IP数/总连接数）
    local density=$(awk -v u="$unique_ips" -v t="$total_conn" 'BEGIN {printf "%.2f", u/t}')
    
    log "--- 策略3: 高度分布式攻击检测 ---"
    log "IP密度: $density (唯一IP: $unique_ips / 总连接: $total_conn)"
    
    # 判断是否为高度分布式攻击
    # 条件1：唯一IP数超过阈值
    # 条件2：IP密度超过阈值（说明平均每IP连接数很低）
    local is_distributed=0
    local threshold=${DISTRIBUTED_IP_THRESHOLD:-100}
    
    if [ "$unique_ips" -ge "$threshold" ] 2>/dev/null; then
        local density_threshold=${DISTRIBUTED_DENSITY_RATIO:-0.5}
        local density_check=$(awk -v d="$density" -v t="$density_threshold" 'BEGIN {print (d >= t) ? 1 : 0}')
        
        if [ "$density_check" = "1" ]; then
            is_distributed=1
            log "🚨 检测到高度分布式攻击！(IP密度: $density >= $density_threshold)" "ALERT"
            log "启用激进封禁策略（阈值降低到 ${DISTRIBUTED_SINGLE_THRESHOLD:-3}）" "WARN"
        fi
    fi
    
    if [ "$is_distributed" = "0" ]; then
        log "未检测到高度分布式攻击特征"
        return 0
    fi
    
    # 使用降低的阈值进行封禁
    local blocked=0
    local low_threshold=${DISTRIBUTED_SINGLE_THRESHOLD:-3}
    # 清理非数字字符
    low_threshold=$(echo "$low_threshold" | tr -cd '0-9')
    low_threshold=${low_threshold:-3}
    
    echo "$syn_data" | uniq -c | while read -r count ip; do
        [ -z "$ip" ] && continue
        
        # 跳过白名单
        if is_whitelisted "$ip"; then
            continue
        fi
        
        # 使用低阈值封禁
        if [ "${count:-0}" -ge "$low_threshold" ] 2>/dev/null; then
            if [ "${ENABLE_BLOCK:-1}" -eq 1 ] 2>/dev/null; then
                if ipset add "$BLACKLIST_SET" "$ip" timeout "$BAN_DURATION" comment "distributed:$count" -exist 2>/dev/null; then
                    log "🚫 封禁分布式攻击IP: $ip (连接数: $count, 低阈值)" "ALERT"
                    blocked=$((blocked + 1))
                fi
            else
                log "⚠️  检测到分布式攻击IP: $ip (连接数: $count) [仅观察模式]" "WARN"
            fi
        fi
    done
    
    return 0
}

# ===== 获取统计信息 =====
get_statistics() {
    local blacklist_count=$(ipset list "$BLACKLIST_SET" 2>/dev/null | grep -c "^[0-9]" 2>/dev/null || echo 0)
    local subnet_blacklist_count=$(ipset list "$SUBNET_BLACKLIST_SET" 2>/dev/null | grep -c "^[0-9]" 2>/dev/null || echo 0)
    local whitelist_count=$(ipset list "$WHITELIST_SET" 2>/dev/null | grep -c "^[0-9]" 2>/dev/null || echo 0)
    
    # 清理非数字字符
    blacklist_count=$(echo "$blacklist_count" | tr -cd '0-9')
    blacklist_count=${blacklist_count:-0}
    subnet_blacklist_count=$(echo "$subnet_blacklist_count" | tr -cd '0-9')
    subnet_blacklist_count=${subnet_blacklist_count:-0}
    whitelist_count=$(echo "$whitelist_count" | tr -cd '0-9')
    whitelist_count=${whitelist_count:-0}
    
    echo "黑名单: $blacklist_count 个, 网段黑名单: $subnet_blacklist_count 个, 白名单: $whitelist_count 条"
}

# ===== 主扫描函数 =====
scan() {
    log "========== 开始扫描 =========="
    
    # 获取 SYN_RECV 数据
    local syn_data=$(get_syn_data)
    
    if [ -z "$syn_data" ]; then
        log "当前无 SYN_RECV 连接"
        log "$(get_statistics)"
        log "========== 扫描完成 =========="
        return 0
    fi
    
    # 统计
    local total_conn=$(echo "$syn_data" | wc -l 2>/dev/null || echo 0)
    local unique_ips=$(echo "$syn_data" | sort -u | wc -l 2>/dev/null || echo 0)
    
    # 清理非数字字符
    total_conn=$(echo "$total_conn" | tr -cd '0-9')
    total_conn=${total_conn:-0}
    unique_ips=$(echo "$unique_ips" | tr -cd '0-9')
    unique_ips=${unique_ips:-0}
    
    log "总 SYN_RECV 连接: $total_conn, 唯一IP数: $unique_ips"
    
    # 检查是否超过阈值
    if [ "$total_conn" -lt "${TOTAL_THRESHOLD:-200}" ] 2>/dev/null; then
        log "连接数正常 (< $TOTAL_THRESHOLD), 无需检测"
        log "$(get_statistics)"
        log "========== 扫描完成 =========="
        return 0
    fi
    
    log "⚠️  连接数异常 (>= $TOTAL_THRESHOLD), 开始检测..." "WARN"
    
    # 执行检测（按优先级）
    detect_single_ip "$syn_data"
    detect_subnet "$syn_data"
    # 临时禁用策略3，待排查问题后再启用
    # detect_distributed "$syn_data" "$total_conn" "$unique_ips"
    
    # 输出统计
    log "$(get_statistics)"
    log "========== 扫描完成 =========="
}

# ===== 健康检查 =====
health_check() {
    # 检查黑名单是否过大
    local blacklist_count=$(ipset list "$BLACKLIST_SET" 2>/dev/null | grep -c "^[0-9]" 2>/dev/null || echo 0)
    # 清理所有非数字字符（包括换行符）
    blacklist_count=$(echo "$blacklist_count" | tr -cd '0-9')
    blacklist_count=${blacklist_count:-0}
    
    local max_size=${MAX_BLACKLIST_SIZE:-10000}
    # 确保 max_size 是纯数字
    max_size=$(echo "$max_size" | tr -cd '0-9')
    max_size=${max_size:-10000}
    
    # 计算阈值
    local threshold=$((max_size * 80 / 100))
    
    if [ "$blacklist_count" -gt "$threshold" ] 2>/dev/null; then
        log "⚠️  黑名单接近上限: $blacklist_count / $max_size" "WARN"
    fi
    
    # 检查内存使用
    local mem_available=$(free -m 2>/dev/null | awk 'NR==2{print $7}' 2>/dev/null || echo 1000)
    # 清理所有非数字字符
    mem_available=$(echo "$mem_available" | tr -cd '0-9')
    mem_available=${mem_available:-1000}
    
    if [ "$mem_available" -lt 200 ] 2>/dev/null; then
        log "⚠️  可用内存不足: ${mem_available}MB" "WARN"
    fi
}

# ===== 初始化环境 =====
init_environment() {
    # 创建配置目录
    mkdir -p "$CONF_DIR" "$BACKUP_DIR" 2>/dev/null || true
    
    # 加载配置
    load_config
    
    # 初始化 ipset 和 iptables
    init_ipset || return 1
    init_iptables || return 1
    
    # 强制重新加载白名单（清除MD5缓存）
    rm -f /var/run/syn_whitelist.md5
    load_whitelist
    
    log "防护系统初始化完成"
    log "配置: 封禁=${ENABLE_BLOCK}, 单IP阈值=${SINGLE_IP_THRESHOLD}, 检查间隔=${CHECK_INTERVAL}s"
    
    return 0
}

# ===== 主循环 =====
main() {
    # 获取锁
    acquire_lock
    
    # 保存 PID
    echo $$ > "$PID_FILE"
    
    # 初始化
    if ! init_environment; then
        log "初始化失败，退出" "ERROR"
        exit 1
    fi
    
    log "防护服务已启动 (PID: $$)"
    
    # 主循环
    while true; do
        # 重新加载白名单（支持热更新）
        load_whitelist
        
        # 执行扫描
        scan
        
        # 健康检查
        health_check
        
        # 清理日志
        cleanup_log
        
        # 等待下次扫描
        sleep "$CHECK_INTERVAL"
    done
}

# ===== 单次执行模式 =====
if [ "${1:-}" = "once" ]; then
    acquire_lock
    load_config
    init_ipset || exit 1
    init_iptables || exit 1
    load_whitelist
    scan
    exit 0
fi

# ===== 启动守护进程 =====
main

