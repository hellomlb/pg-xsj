#!/bin/bash
#=============================================================================
# 木木 PG 健康巡检 (mm_pg_health_check) v2.2
# 新增: 文件描述符耗尽检查 (FD)/data_checksums检查/pg_stat_statements深度巡检
# 新增: OS三故障检测(data_sync_retry/collation/THP增强) — fsyncgate/glibc排序/THP
# 新增: P0诊断项(慢SQL/长事务/阻塞会话) + P1增强(网络IO/连通性/登录失败/备份/膨胀)
# 新增: P2可配置阈值(P2) + 诊断模式(--diagnose 见 mm_pg_diag.sh)
# 支持：PostgreSQL / openGauss / Vastbase
# 整合：木木武器库 参数公式(5.1) + 安全加固Checklist(6.2)
# 输出：结构化 HTML 巡检报告
#=============================================================================

set -o pipefail

#################### 配置参数 ####################
export PGHOST="${PGHOST:-127.0.0.1}"
export PGPORT="${PGPORT:-5432}"
export PGUSER="${PGUSER:-postgres}"
export PGPASSWORD="${PGPASSWORD:-}"
export PGDATABASE="${PGDATABASE:-postgres}"
export PGDATA="${PGDATA:-/opt/pg/data}"
GAUSSHOME="${GAUSSHOME:-}"
DB_USER="${DB_USER:-postgres}"
BACKUP_DIR="${BACKUP_DIR:-/data/backup}"
DB_LOG_DIR="${DB_LOG_DIR:-/opt/pg/log}"

# ===== P2: 告警阈值可配置 (可通过环境变量覆盖) =====
WARN_CPU_PCT="${WARN_CPU_PCT:-70}"         # CPU 告警阈值
ERROR_CPU_PCT="${ERROR_CPU_PCT:-80}"        # CPU 错误阈值
FATAL_CPU_PCT="${FATAL_CPU_PCT:-90}"        # CPU 致命阈值
WARN_MEM_AVAIL_PCT="${WARN_MEM_AVAIL_PCT:-30}"   # 内存可用率告警
ERROR_MEM_AVAIL_PCT="${ERROR_MEM_AVAIL_PCT:-20}" # 内存可用率错误
FATAL_MEM_AVAIL_PCT="${FATAL_MEM_AVAIL_PCT:-10}" # 内存可用率致命
WARN_CONN_PCT="${WARN_CONN_PCT:-80}"        # 连接数告警
FATAL_CONN_PCT="${FATAL_CONN_PCT:-90}"      # 连接数致命
WARN_DISK_PCT="${WARN_DISK_PCT:-70}"        # 磁盘告警
ERROR_DISK_PCT="${ERROR_DISK_PCT:-80}"      # 磁盘错误
FATAL_DISK_PCT="${FATAL_DISK_PCT:-90}"      # 磁盘致命
SLOW_SQL_THRESHOLD="${SLOW_SQL_THRESHOLD:-5}"       # 慢SQL阈值(秒)
LONG_TXN_THRESHOLD="${LONG_TXN_THRESHOLD:-1800}"    # 长事务阈值(秒), 默认30分钟
BLOCKING_THRESHOLD="${BLOCKING_THRESHOLD:-30}"       # 阻塞会话持续时间阈值(秒)
NET_PKT_DROP_THRESHOLD="${NET_PKT_DROP_THRESHOLD:-100}"  # 丢包告警阈值
WAL_LAG_WARN_BYTES="${WAL_LAG_WARN_BYTES:-134217728}"   # WAL延迟告警(128MB)
WAL_LAG_ERROR_BYTES="${WAL_LAG_ERROR_BYTES:-1073741824}" # WAL延迟错误(1GB)
INACTIVE_SLOT_FATAL="${INACTIVE_SLOT_FATAL:-1}"     # 非活跃槽致命阈值
BACKUP_STALE_HOURS="${BACKUP_STALE_HOURS:-24}"      # 备份过期阈值(小时)
LOGIN_FAIL_WINDOW="${LOGIN_FAIL_WINDOW:-30}"        # 登录失败采样窗口(秒)

# 结果目录
MYDATE=$(date "+%m%d_%H%M%S")
MYHOST=$(hostname)
RESULT_DIR="/tmp/pgcheck_${MYHOST}_${MYDATE}"
mkdir -p "${RESULT_DIR}"
FILE_OUTPUT="${RESULT_DIR}.html"

#################### 变体检测 ####################
PG_VARIANT=""  # pg / opengauss / vastbase
detect_variant() {
    local ver_info
    if [ -n "$GAUSSHOME" ]; then
        ver_info=$(gsql -W "${PGPASSWORD}" --pset=pager=off -q -A -t -c "SELECT version()" 2>/dev/null || true)
    else
        ver_info=$(psql -h "${PGHOST}" -p "${PGPORT}" -U "${PGUSER}" -d "${PGDATABASE}" -q -A -t -c "SELECT version()" 2>/dev/null || true)
    fi
    if echo "$ver_info" | grep -qi "vastbase"; then
        PG_VARIANT="vastbase"
    elif echo "$ver_info" | grep -qi "opengauss"; then
        PG_VARIANT="opengauss"
    elif echo "$ver_info" | grep -qi "postgresql"; then
        PG_VARIANT="pg"
    else
        echo "WARNING: 无法自动检测数据库变体，假定为标准 PostgreSQL"
        PG_VARIANT="pg"
    fi
}

# SQL 客户端选择
sql_exec() {
    if [ "$PG_VARIANT" = "opengauss" ] || [ "$PG_VARIANT" = "vastbase" ]; then
        gsql -W "${PGPASSWORD}" --pset=pager=off -q -A -t -c "$1" 2>/dev/null
    else
        psql -h "${PGHOST}" -p "${PGPORT}" -U "${PGUSER}" -d "${PGDATABASE}" -q -A -t -c "$1" 2>/dev/null
    fi
}

sql_table() {
    if [ "$PG_VARIANT" = "opengauss" ] || [ "$PG_VARIANT" = "vastbase" ]; then
        gsql -W "${PGPASSWORD}" --pset=pager=off -q -c "$1" 2>/dev/null
    else
        psql -h "${PGHOST}" -p "${PGPORT}" -U "${PGUSER}" -d "${PGDATABASE}" -q -c "$1" 2>/dev/null
    fi
}

#################### 结果记录函数 ####################
wDetail() {
    local key; key=$(echo "$2" | sed 's/[[:space:]]//g')
    echo -e "$1" >> "${RESULT_DIR}/${key}_detail"
}

wResult() {
    local result; result=$(echo "$1" | sed 's/[[:space:]]//g')
    local key;   key=$(echo "$2" | sed 's/[[:space:]]//g')
    local priority
    case "$result" in
        FATAL)   priority=5 ;;
        ERROR)   priority=4 ;;
        WARNING) priority=3 ;;
        NORMAL)  priority=1 ;;  # NORMAL 回退为 NORMAL
        PASS)    priority=1 ;;
        INFO)    priority=2 ;;
        *)       result="UNKOWN"; priority=6 ;;
    esac

    if [ -e "${RESULT_DIR}/${key}_result" ]; then
        local cur
        cur=$(cat "${RESULT_DIR}/${key}_result" 2>/dev/null | cut -d'|' -f2)
        local cur_p
        case "$cur" in
            FATAL)   cur_p=5 ;;
            ERROR)   cur_p=4 ;;
            WARNING) cur_p=3 ;;
            INFO)    cur_p=2 ;;
            NORMAL|PASS)  cur_p=1 ;;
            UNKOWN)  cur_p=6 ;;
            *)       cur_p=7 ;;
        esac
        if [ "$priority" -gt "$cur_p" ]; then
            echo "${result}" > "${RESULT_DIR}/${key}_result"
        fi
    else
        echo "${result}" > "${RESULT_DIR}/${key}_result"
    fi
}

getSQLResult() {
    local sql_result; sql_result=$(echo "$1" | grep -v '^$')
    local res_num;    res_num=$(echo "$sql_result" | wc -l)
    if [ "$res_num" -gt 3 ]; then
        echo "$sql_result" | sed '1,2d;$d' | sed 's/[[:space:]]//g'
    else
        echo ""
    fi
}

read_result() {
    local key; key=$(echo "$1" | sed 's/[[:space:]]//g')
    cat "${RESULT_DIR}/${key}_result" 2>/dev/null || echo "UNKOWN"
}

#################### 系统信息获取 ####################
get_os_info() {
    # CPU
    if [ -f /proc/cpuinfo ]; then
        local cpu_model; cpu_model=$(grep "model name" /proc/cpuinfo 2>/dev/null | head -1 | cut -d: -f2 | xargs)
        local cpu_cores; cpu_cores=$(grep -c processor /proc/cpuinfo 2>/dev/null)
        wDetail "CPU: ${cpu_model} (${cpu_cores} cores)" cpu_info
    fi
    # 内存
    if [ -f /proc/meminfo ]; then
        local mem_total; mem_total=$(grep MemTotal /proc/meminfo | awk '{printf "%.1f GB", $2/1024/1024}')
        local mem_avail; mem_avail=$(grep MemAvailable /proc/meminfo | awk '{printf "%.1f GB", $2/1024/1024}')
        wDetail "Total: ${mem_total} / Available: ${mem_avail}" memory_info
        TOTAL_MEM_KB=$(grep MemTotal /proc/meminfo | awk '{print $2}')
        TOTAL_MEM_GB=$(awk -v m="$TOTAL_MEM_KB" 'BEGIN{printf "%.0f", m/1024/1024}')
    fi
    # 磁盘
    wDetail "$(df -hT 2>/dev/null)" disk_info
    # 网络
    local ip_addr; ip_addr=$(hostname -I 2>/dev/null | awk '{print $1}')
    wDetail "Hostname: ${MYHOST} / IP: ${ip_addr}" os_basic
}

#################### OS 巡检项 ####################
check_os_user_expiry() {
    if command -v chage >/dev/null 2>&1; then
        local expire; expire=$(chage -l "$DB_USER" 2>/dev/null | grep "Password expires" | awk -F: '{print $2}' | xargs)
        wDetail "DB用户 ${DB_USER} 密码过期: ${expire:-never}" os_user_expire
        if echo "$expire" | grep -qi "never"; then
            wResult "NORMAL" os_user_expire
        else
            wResult "WARNING" os_user_expire
        fi
    else
        wResult "UNKOWN" os_user_expire
    fi
}

check_kernel_params() {
    local swappiness; swappiness=$(sysctl -n vm.swappiness 2>/dev/null)
    local shmall;    shmall=$(sysctl -n kernel.shmall 2>/dev/null)
    local shmmax;    shmmax=$(sysctl -n kernel.shmmax 2>/dev/null)
    local dirty_ratio; dirty_ratio=$(sysctl -n vm.dirty_ratio 2>/dev/null)
    local dirty_bg_ratio; dirty_bg_ratio=$(sysctl -n vm.dirty_background_ratio 2>/dev/null)
    local overcommit; overcommit=$(sysctl -n vm.overcommit_memory 2>/dev/null)

    wDetail "vm.swappiness=${swappiness}" kernel_params
    wDetail "kernel.shmall=${shmall}"     kernel_params
    wDetail "kernel.shmmax=${shmmax}"     kernel_params
    wDetail "vm.dirty_ratio=${dirty_ratio}" kernel_params
    wDetail "vm.dirty_background_ratio=${dirty_bg_ratio}" kernel_params
    wDetail "vm.overcommit_memory=${overcommit}" kernel_params

    # 武器库推荐：overcommit_memory=2, swappiness=1 for DB
    local issues=0
    [ "$swappiness" != "1" ] && [ "$swappiness" != "0" ] && issues=$((issues+1))
    [ "$overcommit" != "2" ] && issues=$((issues+1))

    if [ "$issues" -ge 2 ]; then
        wResult "ERROR" kernel_params
    elif [ "$issues" -eq 1 ]; then
        wResult "WARNING" kernel_params
    else
        wResult "NORMAL" kernel_params
    fi
}

check_resource_limits() {
    local limits_file="/etc/security/limits.conf"
    local limits_count; limits_count=$(grep -c "$DB_USER" "$limits_file" 2>/dev/null || echo 0)
    wDetail "$(grep -v '^#' "$limits_file" 2>/dev/null | grep -v '^$')" resource_limits

    if [ "$limits_count" -eq 0 ]; then
        wResult "FATAL" resource_limits
    else
        # 检查 nofile 和 memlock
        local nofile; nofile=$(grep "$DB_USER" "$limits_file" 2>/dev/null | grep nofile | awk '{print $4}')
        local memlock; memlock=$(grep "$DB_USER" "$limits_file" 2>/dev/null | grep memlock | awk '{print $4}')
        if [ -n "$nofile" ] && [ "$nofile" != "unlimited" ] && [ "$nofile" -lt 65536 ]; then
            wResult "WARNING" resource_limits
        else
            wResult "NORMAL" resource_limits
        fi
    fi
}

check_selinux() {
    local sel; sel=$(getenforce 2>/dev/null)
    wDetail "SELinux: ${sel}" selinux
    if [ "$sel" = "Disabled" ] || [ "$sel" = "Permissive" ]; then
        wResult "NORMAL" selinux
    elif [ "$sel" = "Enforcing" ]; then
        wResult "FATAL" selinux
    else
        wResult "UNKOWN" selinux
    fi
}

check_transparent_hugepage() {
    local detail=""
    detail+="===== THP 透明大页检查 (p99 延迟飙升元凶) =====\n\n"
    local thp_enabled; thp_enabled=$(cat /sys/kernel/mm/transparent_hugepage/enabled 2>/dev/null | grep -oP '\[\K\w+')
    local thp_defrag;  thp_defrag=$(cat /sys/kernel/mm/transparent_hugepage/defrag 2>/dev/null | grep -oP '\[\K\w+')
    local thp_details
    thp_details=$(cat /sys/kernel/mm/transparent_hugepage/enabled 2>/dev/null)
    detail+="THP enabled: ${thp_details}\n"
    detail+="THP defrag:  $(cat /sys/kernel/mm/transparent_hugepage/defrag 2>/dev/null)\n\n"

    if [ "$thp_enabled" = "never" ] && [ "$thp_defrag" = "never" ]; then
        detail+="✅ 安全: THP 已禁用，不会因内核内存合并导致后端进程挂起\n"
        wDetail "${detail}" transparent_hugepage
        wResult "NORMAL" transparent_hugepage
    else
        detail+="⚠️ 风险 (FATAL): THP 未完全禁用！\n"
        detail+="   khugepaged 内核线程合并 4KB→2MB 大页时，PG 后端进程可能在内核态挂起数百毫秒\n"
        detail+="   表现为 p99/p99.9 延迟随机飙升，SQL 层面无法追踪\n"
        detail+="   修复: echo never > /sys/kernel/mm/transparent_hugepage/enabled && echo never > /sys/kernel/mm/transparent_hugepage/defrag\n"
        detail+="   持久化: GRUB_CMDLINE_LINUX=\"... transparent_hugepage=never\" 或 systemd service\n"

        # 检查 khugepaged 线程
        local khp_pid; khp_pid=$(ps aux 2>/dev/null | grep '[k]hugepaged' | awk '{print $2}')
        if [ -n "$khp_pid" ]; then
            detail+="   khugepaged PID: ${khp_pid} (活跃中)\n"
        fi
        wDetail "${detail}" transparent_hugepage
        wResult "FATAL" transparent_hugepage
    fi
}

check_af_alg() {
    local detail=""
    detail+="===== AF_ALG 内核加密接口检查 (CVE-2026-31431 CopyFail) =====\n\n"
    local issues=0

    # 1. 检查 algif 模块是否加载
    local loaded_modules
    loaded_modules=$(lsmod 2>/dev/null | grep -E "^algif_" | awk '{print $1, $4}')
    if [ -n "$loaded_modules" ]; then
        detail+="已加载 AF_ALG 模块:\n${loaded_modules}\n"
        detail+="风险: CVE-2026-31431 (CopyFail) 通过 AF_ALG+splice 本地提权，已被野外利用\n"
        detail+="Linux 7.2 已启动 AF_ALG 废弃流程（巨大攻击面）\n"
        issues=$((issues+2))
    else
        detail+="AF_ALG 模块未加载: 安全\n"
    fi
    detail+="\n"

    # 2. 检查是否有进程在使用 AF_ALG socket
    local alg_sockets
    alg_sockets=$(ss -f alg 2>/dev/null | grep -v "^State" | grep -v "^$" | head -10)
    if [ -n "$alg_sockets" ]; then
        detail+="AF_ALG socket 使用中:\n${alg_sockets}\n"
        issues=$((issues+1))
    else
        detail+="无 AF_ALG socket 使用: 安全\n"
    fi
    detail+="\n"

    # 3. 禁用建议
    detail+="建议: PG 服务端一般不依赖 AF_ALG，可安全禁用:\n"
    detail+="  echo 'blacklist algif_skcipher' >> /etc/modprobe.d/blacklist-af_alg.conf\n"
    detail+="  echo 'blacklist algif_hash' >> /etc/modprobe.d/blacklist-af_alg.conf\n"
    detail+="  echo 'blacklist algif_aead' >> /etc/modprobe.d/blacklist-af_alg.conf\n"
    detail+="  echo 'blacklist algif_rng' >> /etc/modprobe.d/blacklist-af_alg.conf\n"
    detail+="  # 立即卸载: modprobe -r algif_skcipher algif_hash algif_aead algif_rng\n"
    detail+="\n"

    wDetail "${detail}" af_alg

    if [ "$issues" -ge 3 ]; then
        wResult "FATAL" af_alg
    elif [ "$issues" -ge 2 ]; then
        wResult "ERROR" af_alg
    elif [ "$issues" -ge 1 ]; then
        wResult "WARNING" af_alg
    else
        wResult "NORMAL" af_alg
    fi
}

check_cpu_usage() {
    local cpu_idle; cpu_idle=$(top -b -n 1 2>/dev/null | grep "Cpu" | awk -F, '{print $4}' | awk '{print $1}' | head -1)
    if [ -n "$cpu_idle" ]; then
        local cpu_used; cpu_used=$(awk -v i="$cpu_idle" 'BEGIN{printf "%.1f", 100-i}')
        wDetail "CPU使用率: ${cpu_used}% (idle: ${cpu_idle}%)" cpu_usage
        local cu; cu=$(awk -v u="$cpu_used" 'BEGIN{printf "%.0f", u*10}')
        if [ "$cu" -ge "${FATAL_CPU_PCT}" ]; then
            wResult "FATAL" cpu_usage
        elif [ "$cu" -ge "${ERROR_CPU_PCT}" ]; then
            wResult "ERROR" cpu_usage
        elif [ "$cu" -ge "${WARN_CPU_PCT}" ]; then
            wResult "WARNING" cpu_usage
        else
            wResult "NORMAL" cpu_usage
        fi
    else
        wResult "UNKOWN" cpu_usage
    fi
}

check_memory_usage() {
    local mem_avail_pct
    if [ -f /proc/meminfo ]; then
        local mem_total; mem_total=$(grep MemTotal /proc/meminfo | awk '{print $2}')
        local mem_avail; mem_avail=$(grep MemAvailable /proc/meminfo | awk '{print $2}')
        mem_avail_pct=$(awk -v a="$mem_avail" -v t="$mem_total" 'BEGIN{printf "%.1f", a/t*100}')
        wDetail "内存可用率: ${mem_avail_pct}%" memory_usage
        local ma; ma=$(awk -v a="$mem_avail_pct" 'BEGIN{printf "%.0f", a}')
        if [ "$ma" -le "${FATAL_MEM_AVAIL_PCT}" ]; then
            wResult "FATAL" memory_usage
        elif [ "$ma" -le "${ERROR_MEM_AVAIL_PCT}" ]; then
            wResult "ERROR" memory_usage
        elif [ "$ma" -le "${WARN_MEM_AVAIL_PCT}" ]; then
            wResult "WARNING" memory_usage
        else
            wResult "NORMAL" memory_usage
        fi
    else
        wResult "UNKOWN" memory_usage
    fi
}

check_disk_usage() {
    local disk_fatal; disk_fatal=$(df -h 2>/dev/null | grep -v Filesystem | sed 's/%//' | awk -v t="${FATAL_DISK_PCT}" '{if($5>t) print $1}')
    local disk_error; disk_error=$(df -h 2>/dev/null | grep -v Filesystem | sed 's/%//' | awk -v t="${ERROR_DISK_PCT}" '{if($5>t) print $1}')
    local disk_warn;  disk_warn=$(df -h 2>/dev/null | grep -v Filesystem | sed 's/%//' | awk -v t="${WARN_DISK_PCT}" '{if($5>t) print $1}')
    wDetail "$(df -hT 2>/dev/null)" disk_usage
    if [ -n "$disk_fatal" ]; then
        wResult "FATAL" disk_usage
    elif [ -n "$disk_error" ]; then
        wResult "ERROR" disk_usage
    elif [ -n "$disk_warn" ]; then
        wResult "WARNING" disk_usage
    else
        wResult "NORMAL" disk_usage
    fi
}

check_syslog_errors() {
    local syslog; syslog=""
    for f in /var/log/messages /var/log/syslog; do
        [ -f "$f" ] && syslog="${syslog}$(grep -iE "FATAL|ERROR|OOM|killed process" "$f" 2>/dev/null | tail -500)\n"
    done
    wDetail "${syslog}" syslog_errors
    if echo "$syslog" | grep -iq "oom"; then
        wResult "ERROR" syslog_errors
    elif echo "$syslog" | grep -iq "error\|fatal"; then
        wResult "WARNING" syslog_errors
    else
        wResult "NORMAL" syslog_errors
    fi
}

check_cron_backup() {
    local cron_list; cron_list=$(crontab -l 2>/dev/null | grep -v '^#' | grep -i backup)
    wDetail "定时任务中备份相关:\n${cron_list:-无}" cron_backup
    if [ -n "$cron_list" ]; then
        wResult "NORMAL" cron_backup
    else
        wResult "WARNING" cron_backup
    fi
}

check_host_uptime() {
    local uptime_sec; uptime_sec=$(awk -F. '{print $1}' /proc/uptime 2>/dev/null)
    local uptime_days; uptime_days=$(awk -v u="$uptime_sec" 'BEGIN{printf "%.0f", u/86400}')
    local last_reboot; last_reboot=$(who -b 2>/dev/null | awk '{print $3,$4}')
    wDetail "已运行 ${uptime_days} 天 / 上次启动: ${last_reboot}" host_uptime
    wResult "INFO" host_uptime
}

# ---- 文件描述符耗尽检查（常被误诊为 PG 问题，根在 OS 层）----
check_file_descriptors() {
    local detail=""
    detail+="===== 文件描述符(File Descriptor)耗尽风险检查 =====\n\n"
    local issues=0

    # C1: 系统级 FD 上限 (fs.file-max)
    local file_max; file_max=$(sysctl -n fs.file-max 2>/dev/null || echo "0")
    detail+="fs.file-max (系统级上限) = ${file_max}\n"
    if [ "$file_max" != "0" ]; then
        if [ "$file_max" -lt 262144 ]; then
            detail+="⚠️ 系统级 FD 上限不足 (< 262144)，建议 : sysctl -w fs.file-max=262144\n"
            issues=$((issues+1))
        fi
    else
        detail+="❌ 无法读取 fs.file-max\n"
        issues=$((issues+1))
    fi

    # C2: 当前已分配/使用中的 FD
    local file_nr; file_nr=$(cat /proc/sys/fs/file-nr 2>/dev/null | awk '{print $1}')
    if [ -n "$file_nr" ] && [ "$file_max" != "0" ] && [ "$file_max" != "0" ]; then
        local fd_pct; fd_pct=$(awk -v used="$file_nr" -v max="$file_max" 'BEGIN{printf "%.1f", used*100/max}')
        detail+="全系统已分配FD总数: ${file_nr} / ${file_max} (${fd_pct}%)\n"
        if [ "$(echo "$fd_pct >= 50" | bc -l 2>/dev/null)" = "1" ]; then
            detail+="⚠️ FD 使用率 >= 50%，接近上限风险\n"
            issues=$((issues+1))
        fi
        if [ "$(echo "$fd_pct >= 80" | bc -l 2>/dev/null)" = "1" ]; then
            detail+="❌ FD 使用率 >= 80%，随时可能耗尽！\n"
            issues=$((issues+3))
        fi
    fi
    detail+="\n"

    # C3: DB 用户 nofile 限制 (limits.conf + 进程实际限制)
    detail+="--- DB 用户 ($DB_USER) 文件描述符限制 ---\n"
    local limits_file="/etc/security/limits.conf"
    local nofile_config; nofile_config=$(grep "^${DB_USER}" "$limits_file" 2>/dev/null | grep nofile)
    detail+="limits.conf 中 nofile 配置: ${nofile_config:-未配置}\n"

    # 获取 DB 用户实际进程的 nofile 限制
    local pg_pid; pg_pid=$(pgrep -f "postgres.*checkpointer" 2>/dev/null | head -1)
    if [ -z "$pg_pid" ]; then
        pg_pid=$(pgrep -f "postgres.*bgwriter" 2>/dev/null | head -1)
    fi
    if [ -z "$pg_pid" ]; then
        pg_pid=$(pgrep -f "^postgres:" 2>/dev/null | head -1)
    fi

    if [ -n "$pg_pid" ]; then
        local soft_limit; soft_limit=$(grep "Max open files" /proc/${pg_pid}/limits 2>/dev/null | awk '{print $4}')
        local hard_limit; hard_limit=$(grep "Max open files" /proc/${pg_pid}/limits 2>/dev/null | awk '{print $5}')
        detail+="进程实际限制 (PID ${pg_pid}): soft=${soft_limit:-未知}, hard=${hard_limit:-未知}\n"

        if [ -n "$soft_limit" ] && [ "$soft_limit" != "unlimited" ]; then
            if [ "$soft_limit" -lt 65536 ]; then
                detail+="⚠️ nofile soft 限制 < 65536，高并发下可能耗尽！\n"
                detail+="   修复: /etc/security/limits.conf 添加 '${DB_USER} soft nofile 65536'\n"
                issues=$((issues+1))
            fi
        fi
    else
        detail+="⚠️ 无法找到 PG 进程 PID，尝试查询 max_connections 替代评估\n"
    fi
    detail+="\n"

    # C4: PG 进程 FD 当前使用量（取最高值）
    detail+="--- PG 进程 FD 实时使用量 ---\n"
    local max_fd=0
    local max_fd_pid=""
    for pid in $(pgrep -f "^postgres:" 2>/dev/null | head -50); do
        local fd_count; fd_count=$(ls /proc/${pid}/fd 2>/dev/null | wc -l)
        if [ "$fd_count" -gt "$max_fd" ]; then
            max_fd=$fd_count
            max_fd_pid=$pid
        fi
    done
    detail+="最高 FD 使用: PID ${max_fd_pid} → ${max_fd} 个\n"
    total_fd=$(pgrep -f "^postgres:" 2>/dev/null | head -50 | while read pid; do ls /proc/${pid}/fd 2>/dev/null | wc -l; done | awk '{s+=$1} END{print s}')
    detail+="所有 PG 进程合计 FD: ${total_fd:-0}\n"
    if [ -n "$soft_limit" ] && [ "$soft_limit" != "unlimited" ] && [ "$max_fd" -gt $((soft_limit * 80 / 100)) ] 2>/dev/null; then
        detail+="⚠️ 单进程 FD 使用超过 soft limit 的 80%\n"
        issues=$((issues+1))
    fi
    detail+="\n"

    # C5: max_connections 风险评估 (高连接数 = 高 FD 需求)
    local pg_max_conn; pg_max_conn=$(sql_exec "SELECT setting FROM pg_settings WHERE name='max_connections'" 2>/dev/null || echo "100")
    detail+="max_connections = ${pg_max_conn}\n"
    if [ "${pg_max_conn:-0}" -gt 1000 ] 2>/dev/null; then
        detail+="⚠️ max_connections > 1000，每个连接至少消耗 1 个 FD，推荐部署 PgBouncer 连接池\n"
        issues=$((issues+2))
    elif [ "${pg_max_conn:-0}" -gt 500 ] 2>/dev/null; then
        detail+="💡 max_connections = ${pg_max_conn}，建议评估是否需要部署连接池\n"
        issues=$((issues+1))
    fi

    # C6: 系统日志中 "Too many open files" 关键字
    for f in /var/log/messages /var/log/syslog /var/log/postgresql*.log "${DB_LOG_DIR}/"*.log; do
        if [ -f "$f" ]; then
            local too_many; too_many=$(grep -ci "Too many open files" "$f" 2>/dev/null || echo "0")
            if [ "$too_many" -gt 0 ]; then
                detail+="❌ 日志中发现 ${too_many} 条 \"Too many open files\" 错误！\n"
                issues=$((issues+3))
            fi
        fi
    done

    # 修复建议
    if [ "$issues" -gt 0 ]; then
        detail+="\n--- 修复建议 ---\n"
        detail+="OS 层修复:\n"
        detail+="  1. /etc/security/limits.conf: ${DB_USER} soft nofile 65536\n"
        detail+="  2. /etc/sysctl.conf: fs.file-max = 262144\n"
        detail+="  3. systemd service: LimitNOFILE=65536\n"
        detail+="PG 层修复:\n"
        detail+="  1. 部署 PgBouncer 连接池，降 max_connections 至 500-1000\n"
        detail+="  2. 合理设置 work_mem 减少临时文件产生\n"
    fi

    wDetail "${detail}" file_descriptors

    if [ "$issues" -ge 5 ]; then
        wResult "FATAL" file_descriptors
    elif [ "$issues" -ge 3 ]; then
        wResult "ERROR" file_descriptors
    elif [ "$issues" -ge 1 ]; then
        wResult "WARNING" file_descriptors
    else
        wResult "NORMAL" file_descriptors
    fi
}

#################### 数据库巡检项 ####################
check_db_version() {
    local ver; ver=$(sql_exec "SELECT version()")
    wDetail "${ver}" db_version
    wResult "INFO" db_version
}

check_db_connections() {
    local total_conn; total_conn=$(sql_exec "SELECT count(*) FROM pg_stat_activity")
    local max_conn;   max_conn=$(sql_exec "SELECT setting FROM pg_settings WHERE name='max_connections'")
    local conn_pct
    conn_pct=$(awk -v t="$total_conn" -v m="$max_conn" 'BEGIN{if(m>0) printf "%.0f", t/m*100; else print 0}')
    wDetail "${total_conn}/${max_conn} (${conn_pct}%)" db_connections
    local act_conn; act_conn=$(sql_exec "SELECT count(*) FROM pg_stat_activity WHERE state='active'")
    wDetail "活跃连接数: ${act_conn}" db_connections

    if [ "$conn_pct" -ge "${FATAL_CONN_PCT}" ]; then
        wResult "FATAL" db_connections
    elif [ "$conn_pct" -ge "${WARN_CONN_PCT}" ]; then
        wResult "WARNING" db_connections
    else
        wResult "NORMAL" db_connections
    fi
}

check_db_replication() {
    local is_standby; is_standby=$(sql_exec "SELECT pg_is_in_recovery()")
    local detail=""
    detail+="===== 流复制状态检查 =====\n\n"
    detail+="角色: $(if [ "$is_standby" = "f" ]; then echo '主库(Primary)'; else echo '备库(Standby)'; fi)\n\n"

    if [ "$is_standby" = "f" ]; then
        # ---- 主库 ----
        # 1. pg_stat_replication 详情
        local repl_info
        repl_info=$(sql_table "SELECT
            application_name AS name,
            client_addr,
            state,
            sync_state,
            pg_wal_lsn_diff(pg_current_wal_lsn(), sent_lsn)::bigint AS sent_lag_bytes,
            pg_wal_lsn_diff(pg_current_wal_lsn(), write_lsn)::bigint AS write_lag_bytes,
            pg_wal_lsn_diff(pg_current_wal_lsn(), flush_lsn)::bigint AS flush_lag_bytes,
            pg_wal_lsn_diff(pg_current_wal_lsn(), replay_lsn)::bigint AS replay_lag_bytes,
            write_lag,
            flush_lag,
            replay_lag
        FROM pg_stat_replication;" 2>/dev/null)
        detail+="--- pg_stat_replication (Standby 状态) ---\n${repl_info:-无 standby 连接}\n\n"

        # 2. 同步复制配置
        local sync_commit; sync_commit=$(sql_exec "SELECT setting FROM pg_settings WHERE name='synchronous_commit'")
        local sync_names; sync_names=$(sql_exec "SELECT setting FROM pg_settings WHERE name='synchronous_standby_names'")
        detail+="--- 同步复制配置 ---\n"
        detail+="synchronous_commit = ${sync_commit}\n"
        detail+="synchronous_standby_names = ${sync_names:-空}\n\n"

        # 3. wal_sender_timeout
        local sender_timeout; sender_timeout=$(sql_exec "SELECT setting FROM pg_settings WHERE name='wal_sender_timeout'")
        detail+="wal_sender_timeout = ${sender_timeout}\n\n"

        # 判定
        local standby_cnt; standby_cnt=$(echo "$repl_info" | grep -c 'streaming' 2>/dev/null || echo "0")
        if [ "$standby_cnt" = "0" ]; then
            wResult "INFO" db_replication
        else
            local max_replay_lag; max_replay_lag=$(sql_exec "SELECT COALESCE(max(pg_wal_lsn_diff(pg_current_wal_lsn(), replay_lsn)::bigint), 0) FROM pg_stat_replication WHERE state='streaming'" 2>/dev/null || echo "0")
            if [ "$max_replay_lag" -gt 1073741824 ] 2>/dev/null; then
                wResult "ERROR" db_replication
            elif [ "$max_replay_lag" -gt 134217728 ] 2>/dev/null; then
                wResult "WARNING" db_replication
            else
                wResult "NORMAL" db_replication
            fi
        fi
    else
        # ---- 备库 ----
        # 1. WAL receive / replay LSN
        local recv_lsn; recv_lsn=$(sql_exec "SELECT pg_last_wal_receive_lsn()::text" 2>/dev/null || echo "")
        local replay_lsn; replay_lsn=$(sql_exec "SELECT pg_last_wal_replay_lsn()::text" 2>/dev/null || echo "")
        local recv_diff; recv_diff=$(sql_exec "SELECT pg_wal_lsn_diff(pg_last_wal_receive_lsn(), pg_last_wal_replay_lsn())::bigint" 2>/dev/null || echo "0")
        detail+="--- WAL 接收/重放状态 ---\n"
        detail+="receive_lsn = ${recv_lsn}\n"
        detail+="replay_lsn  = ${replay_lsn}\n"
        detail+="receive_replay_lag_bytes = ${recv_diff}\n\n"

        # 2. pg_stat_wal_receiver 详情
        local wal_recv
        wal_recv=$(sql_table "SELECT
            status,
            pg_wal_lsn_diff(pg_last_wal_receive_lsn(), pg_last_wal_replay_lsn())::bigint AS lag_bytes,
            last_msg_send_time,
            last_msg_receipt_time,
            latest_end_time
        FROM pg_stat_wal_receiver;" 2>/dev/null)
        detail+="--- pg_stat_wal_receiver ---\n${wal_recv}\n\n"

        # 3. 恢复暂停状态
        local is_paused; is_paused=$(sql_exec "SELECT pg_is_wal_replay_paused()" 2>/dev/null || echo "f")
        detail+="replay_paused = ${is_paused}\n\n"

        # 判定
        if [ "$is_paused" = "t" ]; then
            wResult "ERROR" db_replication
        elif [ "$recv_diff" -gt 1073741824 ] 2>/dev/null; then
            wResult "ERROR" db_replication
        elif [ "$recv_diff" -gt 134217728 ] 2>/dev/null; then
            wResult "WARNING" db_replication
        else
            wResult "NORMAL" db_replication
        fi
    fi

    # ---- 通用：Replication Slots 状态 ----
    local slot_info
    slot_info=$(sql_table "SELECT
        slot_name,
        slot_type,
        database,
        active,
        pg_wal_lsn_diff(pg_current_wal_lsn(), restart_lsn)::bigint AS wal_retained_bytes,
        CASE WHEN active = 'f' THEN '!!! INACTIVE - WAL堆积风险' ELSE '' END AS warning
    FROM pg_replication_slots
    ORDER BY pg_wal_lsn_diff(pg_current_wal_lsn(), restart_lsn) DESC;" 2>/dev/null)
    detail+="--- 全部 Replication Slots ---\n${slot_info:-无复制槽}\n\n"

    # 检查 inactive slot
    local inactive_cnt; inactive_cnt=$(sql_exec "SELECT count(*) FROM pg_replication_slots WHERE active='f'" 2>/dev/null || echo "0")
    detail+="非活跃槽: ${inactive_cnt} 个\n"
    if [ "$inactive_cnt" -gt 0 ]; then
        wResult "FATAL" db_replication
    fi

    wDetail "${detail}" db_replication
}

check_db_archive() {
    local detail=""
    detail+="===== 归档检查 =====\n\n"
    local issues=0

    local archive_mode; archive_mode=$(sql_exec "SELECT setting FROM pg_settings WHERE name='archive_mode'")
    detail+="archive_mode = ${archive_mode}\n"

    if [ "$archive_mode" = "off" ] || [ -z "$archive_mode" ]; then
        detail+="警告: 归档未开启！\n"
        wDetail "${detail}" db_archive
        wResult "FATAL" db_archive
        return
    fi

    # 归档命令
    local archive_cmd; archive_cmd=$(sql_exec "SELECT setting FROM pg_settings WHERE name='archive_command'")
    detail+="archive_command = ${archive_cmd}\n"

    # pg_stat_archiver 统计
    local archiver_stats
    archiver_stats=$(sql_table "SELECT
        archived_count,
        failed_count,
        last_archived_wal,
        last_archived_time,
        last_failed_wal,
        last_failed_time,
        stats_reset
    FROM pg_stat_archiver;" 2>/dev/null)
    detail+="--- pg_stat_archiver ---\n${archiver_stats}\n\n"

    local failed_count; failed_count=$(sql_exec "SELECT failed_count FROM pg_stat_archiver" 2>/dev/null || echo "0")
    local archived_count; archived_count=$(sql_exec "SELECT archived_count FROM pg_stat_archiver" 2>/dev/null || echo "0")
    detail+="归档成功: ${archived_count} 次 / 失败: ${failed_count} 次\n"

    if [ "$failed_count" -gt 0 ]; then
        detail+="警告: 存在归档失败！\n"
        issues=$((issues+2))
    fi

    # 归档延迟（距上次归档时间）
    local last_archived_sec
    last_archived_sec=$(sql_exec "SELECT EXTRACT(epoch FROM now() - last_archived_time)::int FROM pg_stat_archiver WHERE last_archived_time IS NOT NULL" 2>/dev/null || echo "0")
    if [ -n "$last_archived_sec" ] && [ "$last_archived_sec" != "0" ]; then
        detail+="距上次归档: ${last_archived_sec} 秒\n"
        if [ "$last_archived_sec" -gt 3600 ]; then
            detail+="警告: 超过1小时未归档，可能存在问题\n"
            issues=$((issues+1))
        fi
    fi

    # 归档超时
    local archive_timeout; archive_timeout=$(sql_exec "SELECT setting FROM pg_settings WHERE name='archive_timeout'")
    detail+="archive_timeout = ${archive_timeout}s\n"

    wDetail "${detail}" db_archive

    if [ "$issues" -ge 3 ]; then
        wResult "ERROR" db_archive
    elif [ "$issues" -ge 1 ]; then
        wResult "WARNING" db_archive
    else
        wResult "NORMAL" db_archive
    fi
}

check_db_logical_replication() {
    local detail=""
    detail+="===== 逻辑复制检查 =====\n\n"
    local issues=0

    # 1. Publications
    local pub_list
    pub_list=$(sql_table "SELECT pubname, puballtables, pubinsert, pubupdate, pubdelete, pubtruncate FROM pg_publication;" 2>/dev/null)
    detail+="--- Publications ---\n${pub_list:-无发布}\n\n"

    local pub_count; pub_count=$(sql_exec "SELECT count(*) FROM pg_publication" 2>/dev/null || echo "0")

    if [ "$pub_count" -gt 0 ]; then
        local pub_tables
        pub_tables=$(sql_table "SELECT p.pubname, n.nspname AS schema, c.relname AS table_name
        FROM pg_publication p
        JOIN pg_publication_rel pr ON pr.prpubid = p.oid
        JOIN pg_class c ON c.oid = pr.prrelid
        JOIN pg_namespace n ON n.oid = c.relnamespace
        ORDER BY p.pubname, n.nspname, c.relname;" 2>/dev/null)
        detail+="--- Publication Tables ---\n${pub_tables}\n\n"
    fi

    # 2. Subscriptions
    local sub_list
    sub_list=$(sql_table "SELECT subname, subenabled, subpublications, subslotname, subsynccommit FROM pg_subscription;" 2>/dev/null)
    detail+="--- Subscriptions ---\n${sub_list:-无订阅}\n\n"

    local sub_count; sub_count=$(sql_exec "SELECT count(*) FROM pg_subscription" 2>/dev/null || echo "0")

    if [ "$sub_count" -gt 0 ]; then
        # 3. Subscription 统计
        local sub_stats
        sub_stats=$(sql_table "SELECT
            subname,
            pid,
            received_lsn::text,
            latest_end_lsn::text,
            latest_end_time,
            last_msg_send_time,
            last_msg_receipt_time
        FROM pg_stat_subscription;" 2>/dev/null)
        detail+="--- Subscription Stats ---\n${sub_stats}\n\n"

        # 检查是否有停止同步的 subscription
        local inactive_sub
        inactive_sub=$(sql_exec "SELECT count(*) FROM pg_stat_subscription WHERE received_lsn IS NULL OR last_msg_receipt_time < now() - interval '5 minutes'" 2>/dev/null || echo "0")
        if [ "$inactive_sub" -gt 0 ]; then
            detail+="警告: ${inactive_sub} 个 subscription 可能已停止同步\n"
            issues=$((issues+1))
        fi

        # 4. Subscription Worker 错误检查 (PG17+)
        local pg_ver; pg_ver=$(sql_exec "SELECT current_setting('server_version_num')::int" 2>/dev/null || echo "0")
        if [ "$pg_ver" -ge 170000 ] 2>/dev/null; then
            local worker_stats
            worker_stats=$(sql_table "SELECT
                subname,
                relid::regclass::text AS relation,
                last_error,
                last_error_time,
                pg_wal_lsn_diff(pg_current_wal_lsn(), last_error_relay_lsn)::bigint AS error_relay_lag,
                worker_error_count,
                exit_count
            FROM pg_stat_subscription_workers
            WHERE last_error IS NOT NULL OR worker_error_count > 0 OR exit_count > 3;" 2>/dev/null)
            if [ -n "$worker_stats" ]; then
                detail+="--- Subscription Worker 错误记录 ---\n${worker_stats}\n\n"
                local err_workers
                err_workers=$(sql_exec "SELECT count(*) FROM pg_stat_subscription_workers WHERE last_error IS NOT NULL" 2>/dev/null || echo "0")
                local high_exit
                high_exit=$(sql_exec "SELECT count(*) FROM pg_stat_subscription_workers WHERE exit_count > 10" 2>/dev/null || echo "0")
                if [ "$err_workers" -gt 0 ]; then
                    detail+="警告: ${err_workers} 个 worker 存在最后错误记录\n"
                    issues=$((issues+2))
                fi
                if [ "$high_exit" -gt 0 ]; then
                    detail+="警告: ${high_exit} 个 worker 异常退出次数过多(>10)\n"
                    issues=$((issues+1))
                fi
            fi
        else
            detail+="Subscription Worker 详情需 PG17+ (当前版本不支持 pg_stat_subscription_workers)\n"
        fi
    fi

    # 2.5 复制角色 statement_timeout 检查（⚠️ 逻辑复制初始表拷贝陷阱）
    # 如果用于复制的角色有非零 statement_timeout，初始表拷贝（长事务）会被超时终止
    # → 自动重试 → 死元组以百万级累积 → 表无限膨胀（Stormatics 实战案例：50GB→400GB+）
    local repl_timeout_roles
    repl_timeout_roles=$(sql_table "SELECT
        rolname,
        split_part(unnest(rolconfig), '=', 1) AS param,
        split_part(unnest(rolconfig), '=', 2) AS value
    FROM pg_roles
    WHERE rolcanlogin = true
      AND rolconfig::text LIKE '%statement_timeout%'
      AND split_part(unnest(rolconfig), '=', 2) != '0';" 2>/dev/null)
    if [ -n "$repl_timeout_roles" ]; then
        detail+="--- 可登录角色的 statement_timeout 设置 ---\n${repl_timeout_roles}\n"
        local repl_timeout_count
        repl_timeout_count=$(sql_exec "SELECT count(*) FROM (
            SELECT unnest(rolconfig) AS cfg FROM pg_roles
            WHERE rolcanlogin = true AND rolconfig::text LIKE '%statement_timeout%'
        ) t WHERE split_part(cfg, '=', 2) != '0'" 2>/dev/null || echo "0")
        if [ "$repl_timeout_count" -gt 0 ]; then
            detail+="⚠️ 警告: 可登录角色设置了 statement_timeout，如果该角色用于逻辑复制，初始表拷贝阶段可能被超时终止导致死元组爆炸！\n"
            detail+="   建议: ALTER ROLE <复制角色> SET statement_timeout = 0;\n"
            issues=$((issues+1))
        fi
    fi
    detail+="\n"

    # 3. 逻辑复制槽 WAL 堆积
    local logical_slots
    logical_slots=$(sql_table "SELECT
        slot_name, database, active,
        pg_wal_lsn_diff(pg_current_wal_lsn(), restart_lsn)::bigint AS wal_retained_bytes,
        pg_size_pretty(pg_wal_lsn_diff(pg_current_wal_lsn(), restart_lsn)) AS wal_retained
    FROM pg_replication_slots WHERE slot_type='logical'
    ORDER BY pg_wal_lsn_diff(pg_current_wal_lsn(), restart_lsn) DESC;" 2>/dev/null)
    detail+="--- 逻辑复制槽 WAL 堆积 ---\n${logical_slots:-无逻辑复制槽}\n\n"

    local max_logical_lag
    max_logical_lag=$(sql_exec "SELECT COALESCE(max(pg_wal_lsn_diff(pg_current_wal_lsn(), restart_lsn)::bigint), 0) FROM pg_replication_slots WHERE slot_type='logical'" 2>/dev/null || echo "0")
    if [ "$max_logical_lag" -gt 5368709120 ] 2>/dev/null; then
        detail+="警告: 逻辑复制槽 WAL 堆积超过 5GB，磁盘满风险！\n"
        issues=$((issues+2))
    elif [ "$max_logical_lag" -gt 1073741824 ] 2>/dev/null; then
        detail+="警告: 逻辑复制槽 WAL 堆积超过 1GB\n"
        issues=$((issues+1))
    fi

    wDetail "${detail}" db_logical_replication

    if [ "$pub_count" = "0" ] && [ "$sub_count" = "0" ]; then
        wResult "INFO" db_logical_replication
    elif [ "$issues" -ge 2 ]; then
        wResult "ERROR" db_logical_replication
    elif [ "$issues" -eq 1 ]; then
        wResult "WARNING" db_logical_replication
    else
        wResult "NORMAL" db_logical_replication
    fi
}

check_db_data_sync_retry() {
    local detail=""
    detail+="===== data_sync_retry 检查 (fsyncgate 防护) =====\n\n"

    local pg_version_major
    pg_version_major=$(sql_exec "SELECT current_setting('server_version_num')::int / 10000" 2>/dev/null || echo "0")

    if [ "$pg_version_major" -lt 11 ] 2>/dev/null; then
        detail+="⚠️  PG $(sql_exec "SELECT version()" 2>/dev/null | grep -oP '\d+\.\d+' | head -1) 不支持 data_sync_retry 参数 (PG 11+ 才有)\n"
        detail+="   建议升级到 PG 11+ 修复 fsyncgate 问题\n"
        wDetail "${detail}" db_data_sync_retry
        wResult "ERROR" db_data_sync_retry
        return
    fi

    local data_sync_retry
    data_sync_retry=$(sql_exec "SELECT setting FROM pg_settings WHERE name='data_sync_retry'" 2>/dev/null || echo "unknown")
    detail+="data_sync_retry = ${data_sync_retry}\n\n"

    if [ "$data_sync_retry" = "off" ]; then
        detail+="✅ 安全: fsync 失败时 PG 立即 PANIC→崩溃恢复→WAL replay，保证数据安全\n"
        wDetail "${detail}" db_data_sync_retry
        wResult "NORMAL" db_data_sync_retry
    else
        detail+="⛔ 风险 (FATAL): data_sync_retry = ${data_sync_retry}\n"
        detail+="   Linux 内核可能在块设备写入错误后清除错误状态，导致 fsync 返回假成功\n"
        detail+="   已提交的事务可能未写入磁盘！崩溃重启后数据静默丢失 (fsyncgate)\n"
        detail+="   修复: ALTER SYSTEM SET data_sync_retry = off; SELECT pg_reload_conf();\n"
        detail+="   原理: off 时 fsync 失败→PANIC→WAL replay 重新写入，宁可崩溃不丢数据\n"
        wDetail "${detail}" db_data_sync_retry
        wResult "FATAL" db_data_sync_retry
    fi
}

# ---- data_checksums 检查（13年演进：PG18默认开启 → PG19在线修改）----
check_db_data_checksums() {
    local detail=""
    detail+="===== data_checksums 页面校验和检查 (武器库新增) =====\n\n"
    local issues=0

    local pg_ver; pg_ver=$(sql_exec "SELECT current_setting('server_version_num')::int" 2>/dev/null || echo "0")

    # D1: 当前 data_checksums 状态
    local dcs; dcs=$(sql_exec "SHOW data_checksums" 2>/dev/null || echo "unknown")
    detail+="data_checksums = ${dcs}\n"

    if [ "$dcs" = "on" ]; then
        detail+="✅ 页面校验和已启用，可检测磁盘数据损坏\n"
    elif [ "$dcs" = "off" ]; then
        detail+="⚠️ 页面校验和未启用！无法检测磁盘层面的静默数据损坏\n"
        if [ "$pg_ver" -ge 180000 ] 2>/dev/null; then
            detail+="⚠️ PG 18+ 新集群默认开启，当前关闭可能是旧集群升级或手动关闭\n"
        fi
        detail+="   修复 (需停机): pg_checksums --enable -D \$PGDATA\n"
        issues=$((issues+2))
    fi
    detail+="\n"

    # D2: 校验和失败次数监控
    detail+="--- 校验和失败监控 ---\n"
    local total_cf; total_cf=$(sql_exec "SELECT COALESCE(sum(checksum_failures), 0) FROM pg_stat_database" 2>/dev/null || echo "0")
    detail+="checksum_failures 总计: ${total_cf}\n"
    if [ "$total_cf" != "0" ] && [ "$total_cf" != "" ]; then
        local cf_detail; cf_detail=$(sql_exec "SELECT string_agg(datname || '=' || checksum_failures, ', ' ORDER BY datname) FROM pg_stat_database WHERE checksum_failures > 0" 2>/dev/null || echo "")
        detail+="按数据库: ${cf_detail}\n"
        detail+="❌ 发现校验和失败！数据可能已损坏，请立即排查存储层！\n"
        issues=$((issues+5))
    else
        detail+="✅ 无校验和失败记录\n"
    fi
    detail+="\n"

    # D3: ignore_checksum_failure 状态
    local icf; icf=$(sql_exec "SELECT setting FROM pg_settings WHERE name='ignore_checksum_failure'" 2>/dev/null || echo "off")
    detail+="ignore_checksum_failure = ${icf}\n"
    if [ "$icf" = "on" ]; then
        detail+="❌ 忽略校验和失败！此设置仅限紧急恢复，正常运行时必须为 off\n"
        issues=$((issues+3))
    fi
    detail+="\n"

    # D4: 版本演进提示 + pg_upgrade 兼容性
    if [ "$pg_ver" -lt 120000 ] 2>/dev/null; then
        detail+="💡 PG < 12: 不支持 pg_checksums 工具，需 initdb 重建集群才能开启校验和\n"
    elif [ "$pg_ver" -lt 180000 ] 2>/dev/null; then
        detail+="💡 PG 12-17: 支持 pg_checksums --enable 离线开启 (需停机)\n"
        detail+="💡 若计划 pg_upgrade 升级，源/目标集群校验和配置必须统一\n"
    elif [ "$pg_ver" -lt 190000 ] 2>/dev/null; then
        detail+="💡 PG 18: 新集群默认开启 data_checksums，强烈建议对旧集群离线开启\n"
    else
        detail+="💡 PG 19+: 计划支持在线修改 data_checksums (以官方 Release Notes 为准)\n"
    fi

    wDetail "${detail}" db_data_checksums

    if [ "$issues" -ge 5 ]; then
        wResult "FATAL" db_data_checksums
    elif [ "$issues" -ge 3 ]; then
        wResult "ERROR" db_data_checksums
    elif [ "$issues" -ge 1 ]; then
        wResult "WARNING" db_data_checksums
    else
        wResult "NORMAL" db_data_checksums
    fi
}

check_db_collation() {
    local detail=""
    detail+="===== Collation 检查 (glibc 排序风险) =====\n\n"

    local non_c_dbs
    non_c_dbs=$(sql_table "SELECT datname, datcollate, datctype, encoding FROM pg_database WHERE datcollate NOT LIKE '%C%' OR datctype NOT LIKE '%C%' ORDER BY datname;" 2>/dev/null)

    local non_c_count
    non_c_count=$(sql_exec "SELECT count(*) FROM pg_database WHERE datcollate NOT LIKE '%C%' OR datctype NOT LIKE '%C%'" 2>/dev/null || echo "0")

    if [ "$non_c_count" = "0" ]; then
        detail+="✅ 所有数据库使用 C/POSIX locale，不受 glibc 排序规则变更影响\n"
        wDetail "${detail}" db_collation
        wResult "NORMAL" db_collation
    else
        detail+="--- 使用非 C locale 的数据库 (${non_c_count} 个) ---\n${non_c_dbs}\n\n"
        detail+="⚠️ 风险 (WARNING): 非 C locale 依赖系统 glibc strcoll() 排序\n"
        detail+="   OS 升级 (尤其是 glibc 2.28) 可能静默改变排序规则 → B-tree 索引逻辑损坏\n"
        detail+="   症状: 查询遗漏行、唯一约束误报冲突、范围查询结果异常\n"
        detail+="   修复: 确认 OS 版本后 REINDEX DATABASE，长期建议迁移至 ICU locale\n"
        detail+="   预防: PG 15+ 支持 CREATE DATABASE ... LC_COLLATE = 'en-US-x-icu'\n"

        # 检查 PG 版本是否支持 ICU
        local pg_ver
        pg_ver=$(sql_exec "SELECT current_setting('server_version_num')::int / 10000" 2>/dev/null || echo "0")
        if [ "$pg_ver" -ge 15 ] 2>/dev/null; then
            local icu_count
            icu_count=$(sql_exec "SELECT count(*) FROM pg_database WHERE datlocprovider = 'i'" 2>/dev/null || echo "0")
            detail+="   PG ${pg_ver} 支持 ICU locale，当前 ICU 数据库数: ${icu_count}\n"
        fi

        wDetail "${detail}" db_collation
        wResult "WARNING" db_collation
    fi
}

check_db_autovacuum() {
    local vac_running; vac_running=$(sql_exec "SELECT count(*) FROM pg_stat_progress_vacuum" 2>/dev/null || echo "0")
    local dead_tup_threshold
    dead_tup_threshold=$(sql_exec "SELECT count(*) FROM pg_stat_user_tables WHERE n_dead_tup > 100000 AND n_live_tup > 0" 2>/dev/null || echo "0")
    wDetail "vacuum_running=${vac_running}, tables_with_100k_dead=${dead_tup_threshold}" db_autovacuum

    if [ "$dead_tup_threshold" -gt 10 ]; then
        wResult "WARNING" db_autovacuum
    else
        wResult "NORMAL" db_autovacuum
    fi
}

check_db_checkpoint() {
    local detail=""
    detail+="===== Checkpoint 统计检查 =====\n\n"
    local issues=0

    # pg_stat_bgwriter checkpoint 统计
    local ckpt_stats
    ckpt_stats=$(sql_table "SELECT
        checkpoints_timed,
        checkpoints_req,
        checkpoint_write_time AS write_time_ms,
        checkpoint_sync_time AS sync_time_ms,
        buffers_checkpoint,
        stats_reset
    FROM pg_stat_bgwriter;" 2>/dev/null)
    detail+="--- pg_stat_bgwriter (Checkpoint 相关) ---\n${ckpt_stats}\n\n"

    # Checkpoint 参数
    local ckpt_timeout; ckpt_timeout=$(sql_exec "SELECT setting FROM pg_settings WHERE name='checkpoint_timeout'")
    local max_wal_size;  max_wal_size=$(sql_exec "SELECT setting FROM pg_settings WHERE name='max_wal_size'")
    local min_wal_size;  min_wal_size=$(sql_exec "SELECT setting FROM pg_settings WHERE name='min_wal_size'")
    local ckpt_completion; ckpt_completion=$(sql_exec "SELECT setting FROM pg_settings WHERE name='checkpoint_completion_target'")
    detail+="--- Checkpoint 参数 ---\n"
    detail+="checkpoint_timeout = ${ckpt_timeout}s\n"
    detail+="max_wal_size = ${max_wal_size}\n"
    detail+="min_wal_size = ${min_wal_size}\n"
    detail+="checkpoint_completion_target = ${ckpt_completion}\n\n"

    # 被迫 checkpoint 比例
    local timed; timed=$(sql_exec "SELECT checkpoints_timed FROM pg_stat_bgwriter" 2>/dev/null || echo "0")
    local req;  req=$(sql_exec "SELECT checkpoints_req FROM pg_stat_bgwriter" 2>/dev/null || echo "0")
    local total_ckpt=$((timed + req))
    detail+="checkpoints_timed(按时间): ${timed} / checkpoints_req(按WAL): ${req}\n"

    if [ "$total_ckpt" -gt 0 ]; then
        local req_pct; req_pct=$(awk -v r="$req" -v t="$total_ckpt" 'BEGIN{printf "%.0f", r/t*100}')
        detail+="请求触发占比: ${req_pct}% (超过50%说明max_wal_size太小)\n"
        if [ "$req_pct" -gt 70 ]; then
            detail+="警告: 超过70%的checkpoint由WAL触发，建议增大max_wal_size\n"
            issues=$((issues+2))
        elif [ "$req_pct" -gt 50 ]; then
            detail+="警告: 超过50%的checkpoint由WAL触发，考虑增大max_wal_size\n"
            issues=$((issues+1))
        fi

        local write_time; write_time=$(sql_exec "SELECT checkpoint_write_time FROM pg_stat_bgwriter" 2>/dev/null || echo "0")
        local sync_time;  sync_time=$(sql_exec "SELECT checkpoint_sync_time FROM pg_stat_bgwriter" 2>/dev/null || echo "0")
        local avg_write
        avg_write=$(awk -v w="$write_time" -v t="$total_ckpt" 'BEGIN{printf "%.0f", w/t}')
        local avg_sync
        avg_sync=$(awk -v s="$sync_time" -v t="$total_ckpt" 'BEGIN{printf "%.0f", s/t}')
        detail+="平均 write_time: ${avg_write}ms / sync_time: ${avg_sync}ms\n"
        if [ "$avg_write" -gt 30000 ]; then
            detail+="警告: 平均 checkpoint 写入时间过长(>30s)，IO性能可能不足\n"
            issues=$((issues+1))
        fi
    fi

    wDetail "${detail}" db_checkpoint

    if [ "$issues" -ge 3 ]; then
        wResult "ERROR" db_checkpoint
    elif [ "$issues" -ge 1 ]; then
        wResult "WARNING" db_checkpoint
    else
        wResult "NORMAL" db_checkpoint
    fi
}

check_db_bgwriter() {
    local detail=""
    detail+="===== Background Writer 统计检查 =====\n\n"
    local issues=0

    # bgwriter 统计
    local bgw_stats
    bgw_stats=$(sql_table "SELECT
        buffers_checkpoint,
        buffers_clean,
        buffers_backend,
        buffers_backend_fsync,
        buffers_alloc,
        maxwritten_clean,
        stats_reset
    FROM pg_stat_bgwriter;" 2>/dev/null)
    detail+="--- pg_stat_bgwriter (BgWriter 相关) ---\n${bgw_stats}\n\n"

    # bgwriter 参数
    local bgw_delay; bgw_delay=$(sql_exec "SELECT setting FROM pg_settings WHERE name='bgwriter_delay'")
    local bgw_lru_maxpages; bgw_lru_maxpages=$(sql_exec "SELECT setting FROM pg_settings WHERE name='bgwriter_lru_maxpages'")
    local bgw_lru_multiplier; bgw_lru_multiplier=$(sql_exec "SELECT setting FROM pg_settings WHERE name='bgwriter_lru_multiplier'")
    detail+="--- BgWriter 参数 ---\n"
    detail+="bgwriter_delay = ${bgw_delay}ms\n"
    detail+="bgwriter_lru_maxpages = ${bgw_lru_maxpages}\n"
    detail+="bgwriter_lru_multiplier = ${bgw_lru_multiplier}\n\n"

    # bgwriter 效率分析
    local clean; clean=$(sql_exec "SELECT buffers_clean FROM pg_stat_bgwriter" 2>/dev/null || echo "0")
    local backend; backend=$(sql_exec "SELECT buffers_backend FROM pg_stat_bgwriter" 2>/dev/null || echo "0")
    local total_buf=$((clean + backend))

    if [ "$total_buf" -gt 0 ]; then
        local backend_pct; backend_pct=$(awk -v b="$backend" -v t="$total_buf" 'BEGIN{printf "%.0f", b/t*100}')
        detail+="--- BgWriter 效率 ---\n"
        detail+="buffers_clean(bgwriter写): ${clean}\n"
        detail+="buffers_backend(backend写): ${backend}\n"
        detail+="backend写入占比: ${backend_pct}% (越低越好, <10%为优秀)\n"
        if [ "$backend_pct" -gt 30 ]; then
            detail+="警告: backend 写入占比过高，bgwriter 不够积极\n"
            issues=$((issues+1))
        fi
    fi

    # maxwritten_clean
    local maxwritten; maxwritten=$(sql_exec "SELECT maxwritten_clean FROM pg_stat_bgwriter" 2>/dev/null || echo "0")
    if [ "$maxwritten" -gt 0 ]; then
        detail+="maxwritten_clean = ${maxwritten} (bgwriter因达到maxpages上限而停止的次数)\n"
        if [ "$maxwritten" -gt 100 ]; then
            detail+="警告: maxwritten_clean 过高，考虑增大 bgwriter_lru_maxpages\n"
            issues=$((issues+1))
        fi
    fi

    # Buffer 命中率
    local buf_hit_ratio
    buf_hit_ratio=$(sql_exec "SELECT round(100.0 * blks_hit / NULLIF(blks_hit + blks_read, 0), 2) FROM pg_stat_database WHERE datname = current_database()" 2>/dev/null || echo "100")
    detail+="\n--- Buffer 命中率 ---\n"
    detail+="shared_buffers hit ratio: ${buf_hit_ratio}%\n"

    local hit_int
    hit_int=$(echo "$buf_hit_ratio" | awk '{printf "%.0f", $1}')
    if [ "$hit_int" -lt 95 ] 2>/dev/null; then
        detail+="警告: Buffer 命中率 < 95%，建议增大 shared_buffers\n"
        issues=$((issues+1))
    fi

    wDetail "${detail}" db_bgwriter

    if [ "$issues" -ge 2 ]; then
        wResult "ERROR" db_bgwriter
    elif [ "$issues" -eq 1 ]; then
        wResult "WARNING" db_bgwriter
    else
        wResult "NORMAL" db_bgwriter
    fi
}

check_db_slru() {
    local detail=""
    detail+="===== SLRU 缓存健康检查 =====\n\n"
    local issues=0

    # pg_stat_slru 全部 SLRU 缓存统计
    local slru_stats
    slru_stats=$(sql_table "SELECT
        name,
        blks_hit,
        blks_read,
        blks_zeroed,
        blks_written,
        blks_exists,
        flushes,
        truncates,
        CASE WHEN blks_hit + blks_read > 0
            THEN round(100.0 * blks_read / (blks_hit + blks_read), 2)
            ELSE 0 END AS read_pct
    FROM pg_stat_slru
    ORDER BY name;" 2>/dev/null)
    detail+="--- pg_stat_slru (全部缓存) ---\n${slru_stats:-无数据}\n\n"

    # 重点：commit_timestamp 缓存（PG16名为 CommitTs，PG17+名为 commit_timestamp）
    local ct_hit; ct_hit=$(sql_exec "SELECT blks_hit FROM pg_stat_slru WHERE name IN ('commit_timestamp', 'CommitTs')" 2>/dev/null || echo "0")
    local ct_read; ct_read=$(sql_exec "SELECT blks_read FROM pg_stat_slru WHERE name IN ('commit_timestamp', 'CommitTs')" 2>/dev/null || echo "0")
    local ct_zero; ct_zero=$(sql_exec "SELECT blks_zeroed FROM pg_stat_slru WHERE name IN ('commit_timestamp', 'CommitTs')" 2>/dev/null || echo "0")

    detail+="--- commit_timestamp SLRU 重点 ---\n"
    detail+="blks_hit = ${ct_hit}, blks_read = ${ct_read}, blks_zeroed = ${ct_zero}\n"

    local ct_total=$((ct_hit + ct_read))
    if [ "$ct_total" -gt 0 ] && [ "$ct_read" -gt 0 ]; then
        local ct_read_pct
        ct_read_pct=$(awk -v r="$ct_read" -v t="$ct_total" 'BEGIN{printf "%.0f", r/t*100}')
        detail+="miss_pct = ${ct_read_pct}%\n"
        if [ "$ct_read_pct" -gt 50 ]; then
            detail+="警告: commit_timestamp SLRU 缓存命中率过低(>50% miss)，考虑增大 commit_timestamp_buffers (PG17+)\n"
            issues=$((issues+2))
            elif [ "$ct_read_pct" -gt 20 ]; then
            detail+="警告: commit_timestamp SLRU 缓存 miss >20%，关注趋势\n"
            issues=$((issues+1))
        fi
    else
        detail+="commit_timestamp 缓存无活动 (可能未开启 track_commit_timestamp)\n"
    fi

    # 其他 SLRU：subtrans（回卷关键，PG16名为 Subtrans）
    local st_hit; st_hit=$(sql_exec "SELECT blks_hit FROM pg_stat_slru WHERE name IN ('subtrans', 'Subtrans')" 2>/dev/null || echo "0")
    local st_read; st_read=$(sql_exec "SELECT blks_read FROM pg_stat_slru WHERE name IN ('subtrans', 'Subtrans')" 2>/dev/null || echo "0")
    local st_total=$((st_hit + st_read))
    if [ "$st_total" -gt 0 ] && [ "$st_read" -gt 0 ]; then
        local st_read_pct
        st_read_pct=$(awk -v r="$st_read" -v t="$st_total" 'BEGIN{printf "%.0f", r/t*100}')
        detail+="\nsubtrans SLRU miss_pct = ${st_read_pct}% (回卷关键缓存)\n"
        if [ "$st_read_pct" -gt 50 ]; then
            detail+="警告: subtrans SLRU 缓存命中率过低，可能影响子事务性能\n"
            issues=$((issues+1))
        fi
    fi

    # SLRU 参数（PG17+ 才有独立 SLRU 缓存大小 GUC）
    local ct_bufs; ct_bufs=$(sql_exec "SELECT setting FROM pg_settings WHERE name='commit_timestamp_buffers'" 2>/dev/null || echo "N/A(<PG17)")
    detail+="\n--- SLRU 参数 ---\ncommit_timestamp_buffers = ${ct_bufs} (PG17+ 提供手动调优)\n"

    wDetail "${detail}" db_slru

    if [ "$issues" -ge 3 ]; then
        wResult "ERROR" db_slru
    elif [ "$issues" -ge 1 ]; then
        wResult "WARNING" db_slru
    else
        wResult "NORMAL" db_slru
    fi
}

check_db_external_calls() {
    local detail=""
    detail+="===== 事务内外部调用审计 =====\n\n"
    local issues=0

    # 检查 pg_stat_statements 是否安装
    local has_ss; has_ss=$(sql_exec "SELECT count(*) FROM pg_extension WHERE extname='pg_stat_statements'" 2>/dev/null || echo "0")
    if [ "$has_ss" = "0" ]; then
        detail+="pg_stat_statements 未安装，跳过外部调用扫描\n"
        wDetail "${detail}" db_external_calls
        wResult "INFO" db_external_calls
        return
    fi

    # 扫描疑似外部调用：因 pg_stat_statements.query 可能含 NULL 字节，SQL 层无法直接过滤。
    # 策略：仅统计总数 + 长事务 ClientRead 检测
    local ss_total; ss_total=$(sql_exec "SELECT count(*) FROM pg_stat_statements WHERE dbid = (SELECT oid FROM pg_database WHERE datname = current_database())" 2>/dev/null || echo "0")
    detail+="--- 外部调用审计 ---\n"
    detail+="pg_stat_statements 查询数: ${ss_total}\n"

    if [ "$ss_total" -gt 500 ]; then
        detail+="提示: 查询量较大(${ss_total})，建议审查是否有在事务内调用外部服务(http/llm/api)的查询\n"
        detail+="      手动检查: SELECT query FROM pg_stat_statements WHERE query ~ 'http' ORDER BY total_exec_time DESC LIMIT 10;\n"
    fi
    detail+="\n"

    # 长事务 + ClientRead 等待（ORBIT 违反检测）
    local clientread_long
    clientread_long=$(sql_exec "SELECT count(*) FROM pg_stat_activity
        WHERE state='active' AND wait_event='ClientRead'
        AND query_start < now() - interval '30 seconds'" 2>/dev/null || echo "0")
    detail+="\n--- ClientRead 大于 30s 的后端 ---\n"
    detail+="数量: ${clientread_long} (可能为事务内等待外部调用)\n"

    if [ "$clientread_long" -gt 3 ]; then
        detail+="警告: ${clientread_long} 个后端 ClientRead > 30s，可能外部调用阻塞事务\n"
        issues=$((issues+1))
    fi

    wDetail "${detail}" db_external_calls

    if [ "$issues" -ge 3 ]; then
        wResult "ERROR" db_external_calls
    elif [ "$issues" -ge 1 ]; then
        wResult "WARNING" db_external_calls
    else
        wResult "NORMAL" db_external_calls
    fi
}

# ---- 统计信息健康度检查 ----
check_db_stat_health() {
    local detail=""
    detail+="===== 统计信息健康度检查 =====\n\n"
    local issues=0

    # --- 1. n_live_tup > n_tup_ins 异常表 ---
    # 正常增量更新下 n_tup_ins >= n_live_tup（累计插入不可能小于当前活元组）
    # 出现 n_live_tup > n_tup_ins 说明：pg_stat_reset() 过、表刚做 ANALYZE、unlogged 表恢复
    detail+="--- 统计信息异常表 (n_live_tup > n_tup_ins) ---\n"
    local anomaly_count
    anomaly_count=$(sql_exec "SELECT count(*) FROM pg_stat_user_tables
        WHERE n_live_tup > 0 AND n_tup_ins >= 0
        AND n_live_tup > n_tup_ins" 2>/dev/null || echo "0")
    detail+="异常表数量: ${anomaly_count}\n"

    if [ "$anomaly_count" -gt 0 ]; then
        local anomaly_list
        anomaly_list=$(sql_exec "SELECT '  ' || schemaname || '.' || relname || ': n_live=' || n_live_tup || ' n_ins=' || n_tup_ins || ' last_analyze=' || COALESCE(last_analyze::text, 'NEVER')
            FROM pg_stat_user_tables
            WHERE n_live_tup > 0 AND n_tup_ins >= 0 AND n_live_tup > n_tup_ins
            ORDER BY n_live_tup DESC LIMIT 20" 2>/dev/null || echo "")
        detail+="异常表列表 (前20):\n${anomaly_list}\n"
        if [ "$anomaly_count" -gt 10 ]; then
            issues=$((issues+2))
        else
            issues=$((issues+1))
        fi
    fi
    detail+="\n"

    # --- 2. 从未执行 VACUUM/ANALYZE 的表 ---
    detail+="--- 从未维护的表 (vacuum_count=0 AND analyze_count=0) ---\n"
    local never_maintained
    never_maintained=$(sql_exec "SELECT count(*) FROM pg_stat_user_tables
        WHERE n_live_tup > 0
        AND vacuum_count = 0 AND autovacuum_count = 0
        AND analyze_count = 0 AND autoanalyze_count = 0" 2>/dev/null || echo "0")
    detail+="从未维护的表数量: ${never_maintained}\n"

    if [ "$never_maintained" -gt 0 ]; then
        local never_list
        never_list=$(sql_exec "SELECT '  ' || schemaname || '.' || relname || ': rows=' || n_live_tup
            FROM pg_stat_user_tables
            WHERE n_live_tup > 0
            AND vacuum_count = 0 AND autovacuum_count = 0
            AND analyze_count = 0 AND autoanalyze_count = 0
            ORDER BY n_live_tup DESC LIMIT 20" 2>/dev/null || echo "")
        detail+="未维护表列表 (前20):\n${never_list}\n"
        if [ "$never_maintained" -gt 5 ]; then
            issues=$((issues+2))
        else
            issues=$((issues+1))
        fi
    fi
    detail+="\n"

    # --- 3. last_autoanalyze 过久 (>7天) ---
    detail+="--- 自动分析超期 (last_autoanalyze > 7天) ---\n"
    local stale_analyze
    stale_analyze=$(sql_exec "SELECT count(*) FROM pg_stat_user_tables
        WHERE n_live_tup > 0
        AND last_autoanalyze IS NOT NULL
        AND last_autoanalyze < now() - interval '7 days'
        AND n_tup_mod > 0" 2>/dev/null || echo "0")
    detail+="有变更且 autoanalyze 超期 7 天: ${stale_analyze}\n"

    if [ "$stale_analyze" -gt 0 ]; then
        local stale_a_list
        stale_a_list=$(sql_exec "SELECT '  ' || schemaname || '.' || relname || ': last_aa=' || last_autoanalyze::date || ' mods=' || n_tup_mod
            FROM pg_stat_user_tables
            WHERE n_live_tup > 0 AND last_autoanalyze < now() - interval '7 days' AND n_tup_mod > 0
            ORDER BY last_autoanalyze ASC LIMIT 20" 2>/dev/null || echo "")
        detail+="超期表列表 (前20):\n${stale_a_list}\n"
        if [ "$stale_analyze" -gt 10 ]; then
            issues=$((issues+2))
        else
            issues=$((issues+1))
        fi
    fi

    # last_autoanalyze IS NULL 但有数据的表（从未被自动分析）
    local never_aa
    never_aa=$(sql_exec "SELECT count(*) FROM pg_stat_user_tables
        WHERE n_live_tup > 0 AND last_autoanalyze IS NULL" 2>/dev/null || echo "0")
    if [ "$never_aa" -gt 0 ]; then
        detail+="从未自动分析的表: ${never_aa} 张\n"
        local never_aa_list
        never_aa_list=$(sql_exec "SELECT '  ' || schemaname || '.' || relname || ': rows=' || n_live_tup
            FROM pg_stat_user_tables
            WHERE n_live_tup > 0 AND last_autoanalyze IS NULL
            ORDER BY n_live_tup DESC LIMIT 20" 2>/dev/null || echo "")
        detail+="${never_aa_list}\n"
        if [ "$never_aa" -gt 5 ]; then
            issues=$((issues+1))
        fi
    fi
    detail+="\n"

    # --- 4. unlogged 表提醒 ---
    detail+="--- Unlogged 表（崩溃恢复后统计归零风险） ---\n"
    local unlogged_count
    unlogged_count=$(sql_exec "SELECT count(*) FROM pg_class
        WHERE relpersistence='u' AND relkind='r' AND relnamespace NOT IN (
            SELECT oid FROM pg_namespace WHERE nspname IN ('pg_catalog', 'information_schema')
        )" 2>/dev/null || echo "0")
    detail+="Unlogged 表数量: ${unlogged_count}\n"
    if [ "$unlogged_count" -gt 0 ]; then
        local ul_list
        ul_list=$(sql_exec "SELECT '  ' || n.nspname || '.' || c.relname
            FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
            WHERE c.relpersistence='u' AND c.relkind='r'
            AND n.nspname NOT IN ('pg_catalog', 'information_schema')
            ORDER BY n.nspname, c.relname" 2>/dev/null || echo "")
        detail+="Unlogged 表列表:\n${ul_list}\n"
        detail+="风险: 系统崩溃或不正常关闭后 unlogged 表数据清空，统计信息也归零\n"
    fi

    wDetail "${detail}" db_stat_health

    if [ "$issues" -ge 4 ]; then
        wResult "ERROR" db_stat_health
    elif [ "$issues" -ge 2 ]; then
        wResult "WARNING" db_stat_health
    else
        wResult "NORMAL" db_stat_health
    fi
}

# ---- GUC 调参合理性检查（Christophe Pettus GUC 系列精华）----
check_guc_tuning_sanities() {
    local detail=""
    detail+="===== GUC 调参合理性检查 =====\n\n"
    local issues=0

    # A1: CPU 成本三参数是否被改动（偏离默认值）
    local cpu_tuple;      cpu_tuple=$(sql_exec "SELECT setting FROM pg_settings WHERE name='cpu_tuple_cost'" 2>/dev/null || echo "0.01")
    local cpu_index_tuple; cpu_index_tuple=$(sql_exec "SELECT setting FROM pg_settings WHERE name='cpu_index_tuple_cost'" 2>/dev/null || echo "0.005")
    local cpu_operator;   cpu_operator=$(sql_exec "SELECT setting FROM pg_settings WHERE name='cpu_operator_cost'" 2>/dev/null || echo "0.0025")

    detail+="--- CPU 成本参数（默认值: 0.01 / 0.005 / 0.0025）---\n"
    detail+="cpu_tuple_cost       = ${cpu_tuple}\n"
    detail+="cpu_index_tuple_cost = ${cpu_index_tuple}\n"
    detail+="cpu_operator_cost    = ${cpu_operator}\n"

    # 允许 ±50% 浮动范围（避免误报）
    if [ "$(echo "$cpu_tuple > 0.015 || $cpu_tuple < 0.005" | bc -l 2>/dev/null)" = "1" ]; then
        detail+="⚠️ cpu_tuple_cost 偏离默认值 >50%，除非有基准测试支撑否则不建议调整\n"
        issues=$((issues+1))
    fi
    if [ "$(echo "$cpu_index_tuple > 0.0075 || $cpu_index_tuple < 0.0025" | bc -l 2>/dev/null)" = "1" ]; then
        detail+="⚠️ cpu_index_tuple_cost 偏离默认值 >50%\n"
        issues=$((issues+1))
    fi
    if [ "$(echo "$cpu_operator > 0.00375 || $cpu_operator < 0.00125" | bc -l 2>/dev/null)" = "1" ]; then
        detail+="⚠️ cpu_operator_cost 偏离默认值 >50%\n"
        issues=$((issues+1))
    fi

    # A2: random_page_cost 是否针对 SSD 调整
    local rpc; rpc=$(sql_exec "SELECT setting FROM pg_settings WHERE name='random_page_cost'" 2>/dev/null || echo "4")
    detail+="\n--- 存储层成本 ---\n"
    detail+="random_page_cost = ${rpc} (SSD 推荐 1.1, HDD 默认 4.0)\n"
    if [ "$rpc" = "4" ]; then
        detail+="💡 random_page_cost=4 为机械硬盘默认值，若使用 SSD 建议降到 1.1\n"
    fi

    # A3: default_statistics_target 是否过低
    local dst; dst=$(sql_exec "SELECT setting FROM pg_settings WHERE name='default_statistics_target'" 2>/dev/null || echo "100")
    detail+="\n--- 统计信息基础 ---\n"
    detail+="default_statistics_target = ${dst} (推荐 >= 100, 复杂查询 >= 500)\n"
    if [ "${dst:-100}" -lt 100 ] 2>/dev/null; then
        detail+="⚠️ 统计信息采样率过低，可能导致行数估算不准（性能问题根因常在此）\n"
        issues=$((issues+1))
    fi

    # A4: effective_cache_size 是否合理
    local ecs; ecs=$(sql_exec "SELECT setting FROM pg_settings WHERE name='effective_cache_size'" 2>/dev/null || echo "4GB")
    detail+="\neffective_cache_size = ${ecs} (建议 内存×0.75)\n"

    wDetail "${detail}" guc_tuning_sanities

    if [ "$issues" -ge 2 ]; then
        wResult "ERROR" guc_tuning_sanities
    elif [ "$issues" -eq 1 ]; then
        wResult "WARNING" guc_tuning_sanities
    else
        wResult "NORMAL" guc_tuning_sanities
    fi
}

# ---- 分区配置健康度检查（PG11+ partition pruning vs constraint_exclusion）----
check_partition_config() {
    local detail=""
    detail+="===== 分区配置健康度检查 (PG11+) =====\n\n"
    local issues=0

    local pg_ver; pg_ver=$(sql_exec "SELECT current_setting('server_version_num')::int" 2>/dev/null || echo "0")

    if [ "$pg_ver" -lt 110000 ] 2>/dev/null; then
        detail+="PG 版本 < 11, partition pruning 未成熟，constraint_exclusion 仍有关注价值\n"
        wDetail "${detail}" partition_config
        wResult "INFO" partition_config
        return
    fi

    # B1: constraint_exclusion 是否被错误地设为 on
    local ce; ce=$(sql_exec "SELECT setting FROM pg_settings WHERE name='constraint_exclusion'" 2>/dev/null || echo "partition")
    detail+="constraint_exclusion = ${ce}\n"
    if [ "$ce" = "on" ]; then
        detail+="❌ PG11+ 不应将 constraint_exclusion 设为 on！\n"
        detail+="   PG11+ 使用专门的 partition pruning 引擎(O(log n))\n"
        detail+="   constraint_exclusion 只对继承子表生效，设为 on 会增加不必要的规划开销\n"
        detail+="   正确做法: 保持默认 'partition'\n"
        issues=$((issues+2))  # 高权重：这是错误操作
    elif [ "$ce" = "off" ]; then
        detail+="⚠️ constraint_exclusion=off，如果有继承子表可能影响裁剪\n"
        issues=$((issues+1))
    else
        detail+="✅ constraint_explacement='${ce}' (PG11+ 正确默认值)\n"
    fi

    # B2: enable_partition_pruning 状态
    local epp; epp=$(sql_exec "SELECT setting FROM pg_settings WHERE name='enable_partition_pruning'" 2>/dev/null || echo "on")
    detail+="enable_partition_pruning = ${epp}\n"
    if [ "$epp" != "on" ]; then
        detail+="❌ 分区裁剪引擎被禁用！声明式分区的性能优势将丧失\n"
        issues=$((issues+2))
    fi

    # B3: 是否存在分区表
    local part_count; part_count=$(sql_exec "SELECT count(*) FROM pg_inherits WHERE inhparent IN (SELECT oid FROM pg_class WHERE relkind='p')" 2>/dev/null || echo "0")
    detail+="\n声明式分区表数量: ${part_count}\n"

    if [ "$part_count" -gt 0 ]; then
        # B4: 未使用 partition pruning 的潜在风险提示
        detail+="💡 提示: PG11+ 声明式分区的裁剪由 partition pruning 引擎处理\n"
        detail+="   不需要也不应该调整 constraint_exclusion 来优化分区性能\n"
    else
        detail+="（无声明式分区表，此项仅作预防性检查）\n"
    fi

    wDetail "${detail}" partition_config

    if [ "$issues" -ge 2 ]; then
        wResult "ERROR" partition_config
    elif [ "$issues" -eq 1 ]; then
        wResult "WARNING" partition_config
    else
        wResult "NORMAL" partition_config
    fi
}

# ---- Query ID 监控链路完整性检查（compute_query_id + pg_stat_statements）----
check_query_id_chain() {
    local detail=""
    detail+="===== Query ID 监控链路完整性检查 =====\n\n"
    local issues=0

    # C1: pg_stat_statements 是否安装
    local has_ss; has_ss=$(sql_exec "SELECT count(*) FROM pg_extension WHERE extname='pg_stat_statements'" 2>/dev/null || echo "0")
    detail+="pg_stat_statements: $([ "$has_ss" -gt 0 ] && echo '✅ 已安装' || echo '❌ 未安装')\n"
    if [ "$has_ss" = "0" ]; then
        detail+="⚠️ compute_query_id=auto 模式下，无 pg_stat_statements 则所有 query_id 返回 NULL\n"
        issues=$((issues+2))
    fi

    # C2: compute_query_id 当前值
    local cqi; cqi=$(sql_exec "SELECT setting FROM pg_settings WHERE name='compute_query_id'" 2>/dev/null || echo "auto")
    detail+="compute_query_id = ${cqi}\n"
    if [ "$cqi" = "off" ]; then
        detail+="❌ query_id 计算已关闭，无法做查询追踪\n"
        issues=$((issues+2))
    fi

    # C3: shared_preload_libraries 中是否有 pg_stat_statements
    local spl; spl=$(sql_exec "SELECT setting FROM pg_settings WHERE name='shared_preload_libraries'" 2>/dev/null || echo "")
    detail+="shared_preload_libraries 包含 pg_stat_statements: "
    if echo "$spl" | grep -q "pg_stat_statements"; then
        detail+="✅\n"
    else
        detail+="❌ (需要重启才能生效)\n"
        if [ "$has_ss" -gt 0 ]; then
            detail+="⚠️ 扩展已创建但不在 preload_libraries 中——可能是从旧版本升级遗留\n"
            issues=$((issues+1))
        fi
    fi

    # C4: log_line_prefix 是否包含 %Q
    local llp; llp=$(sql_exec "SELECT setting FROM pg_settings WHERE name='log_line_prefix'" 2>/dev/null || echo "")
    detail+="log_line_prefix 含 %Q: "
    if echo "$llp" | grep -q '%Q'; then
        detail+="✅\n"
    else
        detail+="❌ 日志中将不含 query_id\n"
        issues=$((issues+1))
    fi

    # C5: 快速验证——当前会话能否拿到非 NULL query_id
    local test_qid; test_qid=$(sql_exec "SELECT query_id FROM pg_stat_activity WHERE pid = pg_backend_pid()" 2>/dev/null || echo "")
    detail+="当前会话 query_id: ${test_qid:-NULL}\n"
    if [ -z "$test_qid" ] || [ "$test_qid" = "" ]; then
        detail+="❌ 当前会话无法获取 query_id——链路不通！\n"
        issues=$((issues+2))
    fi

    # C6: pg_stat_statements 容量检查（ORM 行爆炸预警）
    if [ "$has_ss" -gt 0 ]; then
        local ss_current ss_max ss_pct
        ss_current=$(sql_exec "SELECT count(*) FROM pg_stat_statements" 2>/dev/null || echo "0")
        ss_max=$(sql_exec "SELECT setting::int FROM pg_settings WHERE name='pg_stat_statements.max'" 2>/dev/null || echo "5000")
        if [ "$ss_max" -gt 0 ] 2>/dev/null; then
            ss_pct=$(echo "scale=1; $ss_current * 100 / $ss_max" | bc 2>/dev/null || echo "0")
            detail+="pg_stat_statements 容量: ${ss_current} / ${ss_max} (${ss_pct}%)\n"
            if [ "$(echo "$ss_pct >= 80" | bc 2>/dev/null || echo "0")" = "1" ]; then
                detail+="⚠️ 容量使用率 >= 80%！ORM 碎片化可能已在淘汰旧条目，热门查询统计可能已丢失\n"
                issues=$((issues+1))
            elif [ "$(echo "$ss_pct >= 95" | bc 2>/dev/null || echo "0")" = "1" ]; then
                detail+="❌ 容量使用率 >= 95%！严重碎片化，考虑增大 pg_stat_statements.max 或检查 ORM 查询模式\n"
                issues=$((issues+2))
            fi
        fi
    fi

    wDetail "${detail}" query_id_chain

    if [ "$issues" -ge 3 ]; then
        wResult "ERROR" query_id_chain
    elif [ "$issues" -ge 1 ]; then
        wResult "WARNING" query_id_chain
    else
        wResult "NORMAL" query_id_chain
    fi
}

# ---- pg_stat_statements 深度巡检（条目淘汰/统计重置/IO计时/查询文本/配置陷阱）----
check_pgss_deep() {
    local detail=""
    detail+="===== pg_stat_statements 深度巡检 (条目淘汰/统计重置/IO计时/查询文本) =====\n\n"
    local issues=0

    # P1: 扩展是否已安装
    local has_ss; has_ss=$(sql_exec "SELECT count(*) FROM pg_extension WHERE extname='pg_stat_statements'" 2>/dev/null || echo "0")
    if [ "$has_ss" = "0" ]; then
        detail+="pg_stat_statements 未安装，跳过后续检查\n"
        wDetail "${detail}" pgss_deep
        wResult "INFO" pgss_deep
        return
    fi
    detail+="pg_stat_statements: ✅ 已安装\n\n"

    # P2: 条目淘汰监控 (dealloc)
    detail+="--- 条目淘汰监控 ---\n"
    local dealloc_count; dealloc_count=$(sql_exec "SELECT dealloc FROM pg_stat_statements_info" 2>/dev/null || echo "")
    local stats_reset_ts; stats_reset_ts=$(sql_exec "SELECT stats_reset FROM pg_stat_statements_info" 2>/dev/null || echo "")
    local ss_current; ss_current=$(sql_exec "SELECT count(*) FROM pg_stat_statements" 2>/dev/null || echo "0")
    local ss_max; ss_max=$(sql_exec "SELECT setting::int FROM pg_settings WHERE name='pg_stat_statements.max'" 2>/dev/null || echo "5000")

    detail+="当前条目数 / 上限: ${ss_current} / ${ss_max}\n"
    detail+="累积淘汰次数 (dealloc): ${dealloc_count:-未知}\n"
    detail+="统计重置时间 (stats_reset): ${stats_reset_ts:-未知}\n"

    if [ -n "$dealloc_count" ] && [ "$dealloc_count" != "0" ]; then
        detail+="⚠️ 已发生条目淘汰！热门查询的统计可能已静默丢失\n"
        detail+="   原因: ORM 行爆炸 / IN 列表长度不同 / 高查询周转率\n"
        detail+="   建议: 增大 pg_stat_statements.max (需重启)\n"
        issues=$((issues+1))
    fi

    if [ -n "$ss_max" ] && [ "$ss_max" != "0" ] && [ "$ss_current" != "0" ]; then
        local ss_pct; ss_pct=$(echo "scale=1; $ss_current * 100 / $ss_max" | bc 2>/dev/null || echo "0")
        detail+="容量使用率: ${ss_pct}%\n"
        if [ "$(echo "$ss_pct >= 95" | bc -l 2>/dev/null)" = "1" ]; then
            detail+="❌ 容量 >= 95%！严重碎片化，统计大面积丢失\n"
            issues=$((issues+3))
        elif [ "$(echo "$ss_pct >= 80" | bc -l 2>/dev/null)" = "1" ]; then
            detail+="⚠️ 容量 >= 80%，建议增大 pg_stat_statements.max\n"
            issues=$((issues+1))
        fi
    fi
    detail+="\n"

    # P3: 查询文本文件完整性（文件重写失败 → 全部query变NULL）
    detail+="--- 查询文本完整性 ---\n"
    local null_query_count; null_query_count=$(sql_exec "SELECT count(*) FROM pg_stat_statements WHERE query IS NULL" 2>/dev/null || echo "0")
    detail+="query IS NULL 的条目数: ${null_query_count}\n"
    if [ "$null_query_count" -gt 0 ] && [ "$ss_current" != "0" ]; then
        local null_pct; null_pct=$(echo "scale=1; $null_query_count * 100 / $ss_current" | bc 2>/dev/null || echo "0")
        if [ "$(echo "$null_pct >= 50" | bc -l 2>/dev/null)" = "1" ]; then
            detail+="❌ 超过 50% 的查询文本为 NULL！pgss_query_texts.stat 文件重写可能已失败\n"
            detail+="   风险: 日志中 query='' 或 query=NULL，失去所有查询文本信息\n"
            detail+="   排查: 检查 \$PGDATA/pg_stat_tmp/pgss_query_texts.stat 文件大小\n"
            detail+="   修复: SELECT pg_stat_statements_reset(); 重建查询文本文件\n"
            issues=$((issues+3))
        else
            detail+="⚠️ ${null_query_count} 个条目查询文本为 NULL (占比 ${null_pct}%)\n"
            issues=$((issues+1))
        fi
    else
        detail+="✅ 查询文本完整\n"
    fi
    detail+="\n"

    # P4: IO 计时链路完整性（track_io_timing 全局开关）
    detail+="--- IO 计时链路完整性 ---\n"
    local tio; tio=$(sql_exec "SELECT setting FROM pg_settings WHERE name='track_io_timing'" 2>/dev/null || echo "off")
    detail+="track_io_timing (全局) = ${tio}\n"
    if [ "$tio" = "off" ]; then
        detail+="⚠️ track_io_timing 关闭，pg_stat_statements 中 IO 耗时列 (shared_blk_read_time 等) 恒为 0\n"
        detail+="   影响: 无法区分慢查询的瓶颈在 IO 还是 CPU\n"
        detail+="   建议: ALTER SYSTEM SET track_io_timing = on; SELECT pg_reload_conf(); (开销 < 1%)\n"
        issues=$((issues+1))
    else
        detail+="✅ IO 计时已启用\n"
    fi
    detail+="\n"

    # P5: track_planning 性能开销检查
    detail+="--- 规划统计开销检查 ---\n"
    local tpp; tpp=$(sql_exec "SELECT setting FROM pg_settings WHERE name='pg_stat_statements.track_planning'" 2>/dev/null || echo "off")
    detail+="pg_stat_statements.track_planning = ${tpp}\n"
    if [ "$tpp" = "on" ]; then
        detail+="⚠️ track_planning=on 有显著性能开销: 同一查询形状的自旋锁竞争翻倍\n"
        detail+="   建议: 仅在排查规划问题时临时开启，排查后关闭\n"
        issues=$((issues+1))
    fi
    detail+="\n"

    # P6: track_utility 干扰检查
    detail+="--- 工具语句干扰检查 ---\n"
    local tu; tu=$(sql_exec "SELECT setting FROM pg_settings WHERE name='pg_stat_statements.track_utility'" 2>/dev/null || echo "on")
    detail+="pg_stat_statements.track_utility = ${tu}\n"
    if [ "$tu" = "on" ]; then
        detail+="💡 track_utility=on → COMMIT/BEGIN/ROLLBACK 会占据 Top N，干扰核心查询排名\n"
        detail+="   ORM 场景下 COMMIT 常因调用次数最高排第一，但无优化价值\n"
    fi
    detail+="\n"

    # P7: PG17 列名变更兼容检查
    local pg_ver; pg_ver=$(sql_exec "SELECT current_setting('server_version_num')::int" 2>/dev/null || echo "0")
    if [ "$pg_ver" -ge 170000 ] 2>/dev/null; then
        detail+="--- PG17+ IO 列名变更提示 ---\n"
        detail+="PG17 重命名: blk_read_time → shared_blk_read_time, blk_write_time → shared_blk_write_time\n"
        detail+="如果监控脚本/仪表盘用 SELECT * 或硬编码旧列名，升级后可能报错或数据错位\n"
    fi

    wDetail "${detail}" pgss_deep

    if [ "$issues" -ge 5 ]; then
        wResult "FATAL" pgss_deep
    elif [ "$issues" -ge 3 ]; then
        wResult "ERROR" pgss_deep
    elif [ "$issues" -ge 1 ]; then
        wResult "WARNING" pgss_deep
    else
        wResult "NORMAL" pgss_deep
    fi
}

# ---- 武器库 5.16: XID & MXID 回卷监控 ----
check_db_xid_mxid() {
    local detail=""
    local issues=0
    detail+="===== XID & MXID 回卷监控 (武器库 5.16) =====\n\n"

    # 数据库级 XID 年龄
    local xid_info
    xid_info=$(sql_table "SELECT datname,
        age(datfrozenxid) AS xid_age,
        (2000000000 - age(datfrozenxid)) AS xid_remaining
    FROM pg_database
    WHERE datistemplate = false
    ORDER BY age(datfrozenxid) DESC;" 2>/dev/null)
    detail+="--- 数据库级 XID 年龄 ---\n${xid_info}\n\n"

    local max_xid_age
    max_xid_age=$(sql_exec "SELECT max(age(datfrozenxid)) FROM pg_database WHERE datistemplate=false" 2>/dev/null || echo "0")
    # XID 回卷阈值: 2亿, WARNING > 1.5亿, ERROR > 1.8亿
    if [ "$max_xid_age" -gt 1800000000 ] 2>/dev/null; then
        issues=$((issues+1))
    elif [ "$max_xid_age" -gt 1500000000 ] 2>/dev/null; then
        issues=$((issues+1))
    fi

    # 数据库级 MXID 年龄
    local mxid_info
    mxid_info=$(sql_table "SELECT datname,
        mxid_age(datminmxid) AS mxid_age,
        (400000000 - mxid_age(datminmxid)) AS mxid_remaining
    FROM pg_database
    WHERE datistemplate = false
    ORDER BY mxid_age(datminmxid) DESC;" 2>/dev/null)
    detail+="--- 数据库级 MXID 年龄 ---\n${mxid_info}\n\n"

    local max_mxid_age
    max_mxid_age=$(sql_exec "SELECT max(mxid_age(datminmxid)) FROM pg_database WHERE datistemplate=false" 2>/dev/null || echo "0")
    # MXID 回卷阈值: 4亿 (autovacuum_multixact_freeze_max_age), WARNING > 3亿, ERROR > 3.6亿
    if [ "$max_mxid_age" -gt 360000000 ] 2>/dev/null; then
        issues=$((issues+1))
    elif [ "$max_mxid_age" -gt 300000000 ] 2>/dev/null; then
        issues=$((issues+1))
    fi

    # 表级 Top 10 XID 年龄
    local tbl_xid
    tbl_xid=$(sql_table "SELECT n.nspname || '.' || c.relname AS table_name,
        age(c.relfrozenxid) AS xid_age
    FROM pg_class c
    JOIN pg_namespace n ON n.oid = c.relnamespace
    WHERE c.relkind = 'r'
    ORDER BY age(c.relfrozenxid) DESC
    LIMIT 10;" 2>/dev/null)
    detail+="--- 表级 XID 年龄 (Top 10) ---\n${tbl_xid}\n\n"

    # 表级 Top 10 MXID 年龄
    local tbl_mxid
    tbl_mxid=$(sql_table "SELECT n.nspname || '.' || c.relname AS table_name,
        mxid_age(c.relminmxid) AS mxid_age
    FROM pg_class c
    JOIN pg_namespace n ON n.oid = c.relnamespace
    WHERE c.relkind = 'r'
    ORDER BY mxid_age(c.relminmxid) DESC
    LIMIT 10;" 2>/dev/null)
    detail+="--- 表级 MXID 年龄 (Top 10) ---\n${tbl_mxid}\n"

    wDetail "${detail}" xid_mxid_wraparound

    if [ "$issues" -ge 2 ]; then
        wResult "FATAL" xid_mxid_wraparound
    elif [ "$issues" -eq 1 ]; then
        wResult "WARNING" xid_mxid_wraparound
    else
        wResult "NORMAL" xid_mxid_wraparound
    fi
}

check_db_locks() {
    local waiting; waiting=$(sql_exec "SELECT count(*) FROM pg_stat_activity WHERE wait_event_type='Lock' AND state='active'" 2>/dev/null || echo "0")
    local idle_in_txn; idle_in_txn=$(sql_exec "SELECT count(*) FROM pg_stat_activity WHERE state='idle in transaction' AND now()-state_change > interval '1 hour'" 2>/dev/null || echo "0")
    wDetail "等待锁会话: ${waiting}, 空闲事务(>1h): ${idle_in_txn}" db_locks

    if [ "$waiting" -gt 5 ]; then
        wResult "ERROR" db_locks
    elif [ "$waiting" -gt 0 ]; then
        wResult "WARNING" db_locks
    else
        wResult "NORMAL" db_locks
    fi

    if [ "$idle_in_txn" -gt 0 ]; then
        wResult "WARNING" db_locks
    fi
}

check_db_tablespace() {
    local tblspc; tblspc=$(sql_table "SELECT spcname, pg_size_pretty(pg_tablespace_size(spcname)) FROM pg_tablespace" 2>/dev/null)
    wDetail "${tblspc}" db_tablespace
    wResult "INFO" db_tablespace
}

# ---- 武器库 5.1: 参数公式验证 ----
check_param_formulas() {
    local cpu_cores
    cpu_cores=$(grep -c processor /proc/cpuinfo 2>/dev/null || echo "1")
    local mem_gb="${TOTAL_MEM_GB:-8}"

    local issues=0
    local detail=""
    detail+="===== 武器库参数公式验证 =====\n"
    detail+="硬件: ${cpu_cores}核 / ${mem_gb}GB\n\n"

    # shared_buffers (公式: min(32GB, 内存*0.25))
    local sb_recommended; sb_recommended=$(awk -v m="$mem_gb" 'BEGIN{r=m*0.25; if(r>32) r=32; printf "%.0f", r}')
    local sb_actual; sb_actual=$(sql_exec "SELECT setting FROM pg_settings WHERE name='shared_buffers'" | sed 's/GB//')
    if echo "$sb_actual" | grep -qi "mb"; then
        sb_actual=$(echo "$sb_actual" | sed 's/MB//' | awk '{printf "%.0f", $1/1024}')
    fi
    detail+="shared_buffers: 推荐=${sb_recommended}GB 实际=$(echo "$sb_actual" | head -1)\n"
    local sb_num; sb_num=$(echo "$sb_actual" | head -1 | awk '{printf "%.0f", $1}')
    if [ -n "$sb_num" ] && [ "$sb_num" != "0" ]; then
        local sb_ratio; sb_ratio=$(awk -v a="$sb_num" -v r="$sb_recommended" 'BEGIN{if(r>0) printf "%.1f", a/r; else print 1}')
        if [ "$(echo "$sb_ratio < 0.5 || $sb_ratio > 2" | bc 2>/dev/null)" = "1" ]; then
            issues=$((issues+1))
        fi
    fi

    # work_mem (公式: max(min(mem_gb*1024/4096, 64), 4) MB)
    local wm_recommended; wm_recommended=$(awk -v m="$mem_gb" 'BEGIN{r=m*1024/4096; if(r>64) r=64; if(r<4) r=4; printf "%.0f", r}')
    local wm_actual; wm_actual=$(sql_exec "SELECT setting FROM pg_settings WHERE name='work_mem'" | sed 's/MB//g')
    detail+="work_mem: 推荐=${wm_recommended}MB 实际=$(echo "$wm_actual" | head -1)\n"
    local wm_num; wm_num=$(echo "$wm_actual" | head -1 | awk '{printf "%.0f", $1}')
    if [ -n "$wm_num" ] && [ "$wm_num" -gt 0 ]; then
        if [ "$wm_num" -lt "$((wm_recommended / 2))" ] || [ "$wm_num" -gt "$((wm_recommended * 4))" ]; then
            issues=$((issues+1))
        fi
    fi

    # effective_cache_size (公式: 内存*0.75)
    local ecs_recommended; ecs_recommended=$(awk -v m="$mem_gb" 'BEGIN{printf "%.0f", m*0.75}')
    local ecs_actual; ecs_actual=$(sql_exec "SELECT setting FROM pg_settings WHERE name='effective_cache_size'" | sed 's/GB//')
    if echo "$ecs_actual" | grep -qi "mb"; then
        ecs_actual=$(echo "$ecs_actual" | sed 's/MB//' | awk '{printf "%.0f", $1/1024}')
    fi
    detail+="effective_cache_size: 推荐=${ecs_recommended}GB 实际=$(echo "$ecs_actual" | head -1)\n"

    # max_wal_size (建议: min(shared_buffers*2, 存储/10), 至少10GB)
    local mws_recommended
    mws_recommended=$(awk -v s="$sb_num" 'BEGIN{r=s*2; if(r<10) r=10; printf "%.0f", r}')
    if [ "$mws_recommended" -gt 64 ]; then mws_recommended=64; fi
    local mws_actual; mws_actual=$(sql_exec "SELECT setting FROM pg_settings WHERE name='max_wal_size'" | sed 's/GB//')
    if echo "$mws_actual" | grep -qi "mb"; then
        mws_actual=$(echo "$mws_actual" | sed 's/MB//' | awk '{printf "%.0f", $1/1024}')
    fi
    detail+="max_wal_size: 推荐=${mws_recommended}GB 实际=$(echo "$mws_actual" | head -1)\n"

    # wal_compression (推荐: on)
    local wc_actual; wc_actual=$(sql_exec "SELECT setting FROM pg_settings WHERE name='wal_compression'")
    detail+="wal_compression: 推荐=on 实际=${wc_actual}\n"
    if [ "$wc_actual" != "on" ]; then issues=$((issues+1)); fi

    # checkpoint_timeout (推荐: 15min+)
    local cpt_actual; cpt_actual=$(sql_exec "SELECT setting FROM pg_settings WHERE name='checkpoint_timeout'" | sed 's/s//')
    detail+="checkpoint_timeout: 推荐=900s(15min) 实际=${cpt_actual}s\n"
    local cpt_num; cpt_num=$(echo "$cpt_actual" | head -1 | awk '{printf "%.0f", $1}')
    if [ -n "$cpt_num" ] && [ "$cpt_num" -lt 600 ]; then issues=$((issues+1)); fi

    # autovacuum_max_workers (公式: max(min(8, CPU/2), 5))
    local avm_recommended; avm_recommended=$(awk -v c="$cpu_cores" 'BEGIN{r=c/2; if(r>8) r=8; if(r<5) r=5; printf "%.0f", r}')
    local avm_actual; avm_actual=$(sql_exec "SELECT setting FROM pg_settings WHERE name='autovacuum_max_workers'")
    detail+="autovacuum_max_workers: 推荐=${avm_recommended} 实际=${avm_actual}\n"

    wDetail "${detail}" param_formulas

    if [ "$issues" -ge 4 ]; then
        wResult "ERROR" param_formulas
    elif [ "$issues" -ge 2 ]; then
        wResult "WARNING" param_formulas
    else
        wResult "NORMAL" param_formulas
    fi
}

# ---- 武器库 6.2: 安全加固 Checklist ----
check_security() {
    local issues=0
    local detail=""
    detail+="===== 安全加固 Checklist =====\n\n"

    # 1. MD5 密码检查
    local md5_count; md5_count=$(sql_exec "SELECT count(*) FROM pg_authid WHERE rolpassword LIKE 'md5%'" 2>/dev/null || echo "0")
    detail+="[${md5_count}/0] MD5密码用户数 (应为0, 全部使用SCRAM-SHA-256)\n"
    if [ "$md5_count" -gt 0 ]; then issues=$((issues+1)); fi

    # 2. 超级用户数量
    local super_count; super_count=$(sql_exec "SELECT count(*) FROM pg_roles WHERE rolsuper=true" 2>/dev/null || echo "0")
    detail+="[${super_count}] 超级用户数 (建议不超过2)\n"
    if [ "$super_count" -gt 2 ]; then issues=$((issues+1)); fi

    # 3. 可创建DB/角色的用户
    local priv_users; priv_users=$(sql_exec "SELECT count(*) FROM pg_roles WHERE rolcreaterole=true OR rolcreatedb=true" 2>/dev/null || echo "0")
    detail+="[${priv_users}] 有创建权限的非超户 (应严格控制)\n"
    if [ "$priv_users" -gt 3 ]; then issues=$((issues+1)); fi

    # 4. PUBLIC schema 权限
    local public_perm
    public_perm=$(sql_exec "SELECT has_schema_privilege('public', 'public', 'CREATE')" 2>/dev/null || echo "t")
    detail+="PUBLIC.CREATE=${public_perm} (生产环境应为f)\n"
    if [ "$public_perm" = "t" ]; then issues=$((issues+1)); fi

    # 5. SECURITY DEFINER 函数
    local secdef_cnt; secdef_cnt=$(sql_exec "SELECT count(*) FROM pg_proc WHERE prosecdef=true AND pronamespace NOT IN (SELECT oid FROM pg_namespace WHERE nspname IN ('pg_catalog','information_schema'))" 2>/dev/null || echo "0")
    detail+="[${secdef_cnt}] SECURITY DEFINER函数 (潜在权限提升风险)\n"
    if [ "$secdef_cnt" -gt 10 ]; then issues=$((issues+1)); fi

    # 6. RLS 检查
    local no_rls_tbls; no_rls_tbls=$(sql_exec "SELECT count(*) FROM pg_tables WHERE rowsecurity=false" 2>/dev/null || echo "0")
    local bypass_rls; bypass_rls=$(sql_exec "SELECT count(*) FROM pg_roles WHERE rolbypassrls=true" 2>/dev/null || echo "0")
    detail+="[${no_rls_tbls}] 未启用RLS的表 / [${bypass_rls}] BYPASSRLS用户\n"

    # 7. pgaudit 检查
    local pgaudit; pgaudit=$(sql_exec "SELECT setting FROM pg_settings WHERE name='shared_preload_libraries'" | grep -c "pgaudit" 2>/dev/null || echo "0")
    detail+="pgaudit=$( [ "$pgaudit" -gt 0 ] && echo "已加载" || echo "未加载" )\n"

    # 8. password_encryption
    local pw_enc; pw_enc=$(sql_exec "SELECT setting FROM pg_settings WHERE name='password_encryption'" 2>/dev/null || echo "unknown")
    detail+="password_encryption=${pw_enc} (应设置为scram-sha-256)\n"
    if [ "$pw_enc" != "scram-sha-256" ]; then issues=$((issues+1)); fi

    # 9. log_connections / log_disconnections
    local log_conn; log_conn=$(sql_exec "SELECT setting FROM pg_settings WHERE name='log_connections'")
    local log_disc; log_disc=$(sql_exec "SELECT setting FROM pg_settings WHERE name='log_disconnections'")
    detail+="log_connections=${log_conn} log_disconnections=${log_disc}\n"

    # 10. ssl
    local ssl_status; ssl_status=$(sql_exec "SELECT setting FROM pg_settings WHERE name='ssl'")
    detail+="ssl=${ssl_status}\n"
    if [ "$ssl_status" != "on" ]; then issues=$((issues+1)); fi

    wDetail "${detail}" security_checklist

    if [ "$issues" -ge 5 ]; then
        wResult "ERROR" security_checklist
    elif [ "$issues" -ge 3 ]; then
        wResult "WARNING" security_checklist
    else
        wResult "NORMAL" security_checklist
    fi
}

check_db_log_errors() {
    # 检查 PG 日志中的 FATAL/ERROR
    local log_dir; log_dir=$(sql_exec "SELECT setting FROM pg_settings WHERE name='log_directory'" 2>/dev/null || echo "pg_log")
    local log_count=0
    if [ -d "$DB_LOG_DIR/$log_dir" ]; then
        log_count=$(grep -rE "FATAL|ERROR|PANIC" "$DB_LOG_DIR/$log_dir" 2>/dev/null | wc -l || echo "0")
    elif [ -d "$PGDATA/$log_dir" ]; then
        log_count=$(grep -rE "FATAL|ERROR|PANIC" "$PGDATA/$log_dir" 2>/dev/null | wc -l || echo "0")
    fi
    wDetail "日志中 FATAL/ERROR 行数: ${log_count}" db_log_errors
    if [ "$log_count" -gt 1000 ]; then
        wResult "ERROR" db_log_errors
    elif [ "$log_count" -gt 100 ]; then
        wResult "WARNING" db_log_errors
    else
        wResult "NORMAL" db_log_errors
    fi
}

#################### P0: 数据库诊断项 ####################

# ---- 当前慢SQL检查 (active query > SLOW_SQL_THRESHOLD 秒) ----
check_db_slow_sql() {
    local detail=""
    detail+="===== 当前慢SQL检查 (阈值: ${SLOW_SQL_THRESHOLD}s) =====\n\n"
    local issues=0

    local slow_count
    slow_count=$(sql_exec "SELECT count(*) FROM pg_stat_activity
        WHERE state='active'
        AND query_start < now() - interval '${SLOW_SQL_THRESHOLD} seconds'
        AND backend_type='client backend'
        AND pid != pg_backend_pid()" 2>/dev/null || echo "0")

    detail+="当前活跃慢SQL数量: ${slow_count}\n\n"

    if [ "$slow_count" -gt 0 ]; then
        local slow_list
        slow_list=$(sql_table "SELECT
            pid,
            usename,
            datname,
            floor(extract(epoch FROM now() - query_start))::int AS duration_sec,
            wait_event_type || '/' || wait_event AS wait,
            state,
            left(query, 200) AS query_snippet
        FROM pg_stat_activity
        WHERE state='active'
        AND query_start < now() - interval '${SLOW_SQL_THRESHOLD} seconds'
        AND backend_type='client backend'
        AND pid != pg_backend_pid()
        ORDER BY now() - query_start DESC
        LIMIT 20;" 2>/dev/null)
        detail+="--- 慢SQL详情 (前20) ---\n${slow_list}\n\n"

        # Top SQL from pg_stat_statements (if available)
        local has_ss; has_ss=$(sql_exec "SELECT count(*) FROM pg_extension WHERE extname='pg_stat_statements'" 2>/dev/null || echo "0")
        if [ "$has_ss" -gt 0 ]; then
            detail+="--- pg_stat_statements 慢查询 Top 10 (全量历史) ---\n"
            local top_slow
            top_slow=$(sql_table "SELECT
                round(total_exec_time::numeric, 1) AS total_ms,
                round(mean_exec_time::numeric, 1) AS mean_ms,
                calls,
                left(query, 150) AS query_snippet
            FROM pg_stat_statements
            WHERE dbid = (SELECT oid FROM pg_database WHERE datname = current_database())
            ORDER BY mean_exec_time DESC
            LIMIT 10;" 2>/dev/null)
            detail+="${top_slow}\n"
        fi
    fi

    wDetail "${detail}" db_slow_sql

    if [ "$slow_count" -gt 10 ]; then
        wResult "ERROR" db_slow_sql
    elif [ "$slow_count" -gt 5 ]; then
        wResult "WARNING" db_slow_sql
    elif [ "$slow_count" -gt 0 ]; then
        wResult "INFO" db_slow_sql
    else
        wResult "NORMAL" db_slow_sql
    fi
}

# ---- 长事务检查 ----
check_db_long_txn() {
    local detail=""
    detail+="===== 长事务检查 (阈值: ${LONG_TXN_THRESHOLD}s) =====\n\n"
    local issues=0

    # 所有状态的长事务
    local long_count
    long_count=$(sql_exec "SELECT count(*) FROM pg_stat_activity
        WHERE xact_start IS NOT NULL
        AND xact_start < now() - interval '${LONG_TXN_THRESHOLD} seconds'
        AND backend_type='client backend'
        AND pid != pg_backend_pid()" 2>/dev/null || echo "0")

    detail+="总长事务数(>${LONG_TXN_THRESHOLD}s): ${long_count}\n\n"

    if [ "$long_count" -gt 0 ]; then
        local long_list
        long_list=$(sql_table "SELECT
            pid,
            usename,
            datname,
            floor(extract(epoch FROM now() - xact_start))::int AS xact_sec,
            floor(extract(epoch FROM now() - query_start))::int AS query_sec,
            state,
            wait_event_type || '/' || wait_event AS wait,
            left(query, 150) AS query_snippet
        FROM pg_stat_activity
        WHERE xact_start IS NOT NULL
        AND xact_start < now() - interval '${LONG_TXN_THRESHOLD} seconds'
        AND backend_type='client backend'
        AND pid != pg_backend_pid()
        ORDER BY xact_start ASC
        LIMIT 20;" 2>/dev/null)
        detail+="--- 长事务详情 (前20) ---\n${long_list}\n\n"

        # idle in transaction 重点
        local iit_count
        iit_count=$(sql_exec "SELECT count(*) FROM pg_stat_activity
            WHERE state='idle in transaction'
            AND xact_start < now() - interval '${LONG_TXN_THRESHOLD} seconds'" 2>/dev/null || echo "0")
        detail+="其中 idle in transaction: ${iit_count} 个 (可能导致 VACUUM 停滞)\n"
    fi

    wDetail "${detail}" db_long_txn

    if [ "$long_count" -gt 5 ]; then
        wResult "ERROR" db_long_txn
    elif [ "$long_count" -gt 0 ]; then
        wResult "WARNING" db_long_txn
    else
        wResult "NORMAL" db_long_txn
    fi
}

# ---- 阻塞会话 + 锁等待链检查 ----
check_db_blocking() {
    local detail=""
    detail+="===== 阻塞会话 & 锁等待链检查 (阈值: ${BLOCKING_THRESHOLD}s) =====\n\n"
    local issues=0

    # 1. 锁等待会话数量
    local lock_waiting
    lock_waiting=$(sql_exec "SELECT count(*) FROM pg_stat_activity
        WHERE wait_event_type='Lock' AND state='active'
        AND query_start < now() - interval '${BLOCKING_THRESHOLD} seconds'" 2>/dev/null || echo "0")
    detail+="锁等待会话数(>${BLOCKING_THRESHOLD}s): ${lock_waiting}\n\n"

    if [ "$lock_waiting" -gt 0 ]; then
        # 2. 构建锁等待链 (blocked ← blocking)
        local lock_chain
        lock_chain=$(sql_table "SELECT
            blocked.pid AS blocked_pid,
            blocked.usename AS blocked_user,
            floor(extract(epoch FROM now() - blocked.query_start))::int AS wait_sec,
            blocked.query AS blocked_query,
            blocking.pid AS blocking_pid,
            blocking.usename AS blocking_user,
            floor(extract(epoch FROM now() - blocking.query_start))::int AS blocker_run_sec,
            blocking.state AS blocker_state,
            blocking.query AS blocking_query
        FROM pg_stat_activity blocked
        JOIN pg_locks bl ON bl.pid = blocked.pid AND bl.granted = false
        JOIN pg_locks bk ON bk.locktype = bl.locktype
            AND bk.database = bl.database
            AND bk.relation = bl.relation
            AND bk.pid != bl.pid
            AND bk.granted = true
        JOIN pg_stat_activity blocking ON blocking.pid = bk.pid
        WHERE blocked.query_start < now() - interval '${BLOCKING_THRESHOLD} seconds'
        ORDER BY blocked.query_start ASC
        LIMIT 30;" 2>/dev/null)
        detail+="--- 锁等待链 (blocked ← blocking) ---\n${lock_chain}\n\n"
    fi

    # 3. Top N 持有最多锁的会话
    detail+="--- Top 10 持有锁最多的会话 ---\n"
    local top_lock_holders
    top_lock_holders=$(sql_table "SELECT
        a.pid,
        a.usename,
        a.datname,
        a.state,
        count(l.pid) AS locks_held,
        left(a.query, 100) AS query
    FROM pg_locks l
    JOIN pg_stat_activity a ON a.pid = l.pid
    WHERE l.granted = true
    GROUP BY a.pid, a.usename, a.datname, a.state, a.query
    ORDER BY count(l.pid) DESC
    LIMIT 10;" 2>/dev/null)
    detail+="${top_lock_holders}\n\n"

    # 4. 锁模式分布
    detail+="--- 锁模式分布 ---\n"
    local lock_modes
    lock_modes=$(sql_table "SELECT
        mode,
        granted,
        count(*) AS cnt
    FROM pg_locks
    WHERE pid != pg_backend_pid()
    GROUP BY mode, granted
    ORDER BY count(*) DESC
    LIMIT 10;" 2>/dev/null)
    detail+="${lock_modes}\n"

    wDetail "${detail}" db_blocking

    if [ "$lock_waiting" -gt 10 ]; then
        wResult "ERROR" db_blocking
    elif [ "$lock_waiting" -gt 0 ]; then
        wResult "WARNING" db_blocking
    else
        wResult "NORMAL" db_blocking
    fi
}

#################### P1: OS 增强检查项 ####################

# ---- 网络IO检查 ----
check_network_io() {
    local detail=""
    detail+="===== 网络IO健康检查 =====\n\n"
    local issues=0

    # 1. 各网卡丢包统计
    if [ -f /proc/net/dev ]; then
        detail+="--- 网卡丢包统计 ---\n"
        local pkt_stats
        pkt_stats=$(awk 'NR>2{
            printf "%-12s RX_drop=%-8s TX_drop=%-8s\n", $1, $5, $12
        }' /proc/net/dev 2>/dev/null)
        detail+="${pkt_stats}\n\n"

        # 检测显著丢包
        local max_rx_drop
        max_rx_drop=$(awk -v t="${NET_PKT_DROP_THRESHOLD}" 'NR>2{if($5>t) print $1":"$5}' /proc/net/dev 2>/dev/null)
        if [ -n "$max_rx_drop" ]; then
            detail+="警告: 以下网卡存在显著丢包 (>${NET_PKT_DROP_THRESHOLD}):\n${max_rx_drop}\n"
            issues=$((issues+1))
        fi
    fi

    # 2. TCP 重传率 (ss)
    if command -v ss >/dev/null 2>&1; then
        detail+="--- TCP 连接统计 ---\n"
        local tcp_summary
        tcp_summary=$(ss -s 2>/dev/null | head -10)
        detail+="${tcp_summary}\n\n"

        local retrans_count
        retrans_count=$(ss -ti 2>/dev/null | grep -c "retrans" || echo "0")
        detail+="TCP 重传连接数: ${retrans_count}\n"
        if [ "${retrans_count:-0}" -gt 50 ] 2>/dev/null; then
            detail+="警告: TCP 重传连接过多，需关注网络质量\n"
            issues=$((issues+1))
        fi
    fi

    # 3. Socket 缓冲区溢出
    if [ -f /proc/net/netstat ]; then
        local tcp_overflow
        tcp_overflow=$(grep "TCPBacklogDrop\|ListenOverflows\|ListenDrops" /proc/net/netstat 2>/dev/null | head -3)
        if [ -n "$tcp_overflow" ]; then
            detail+="--- Socket 溢出统计 ---\n${tcp_overflow}\n\n"
        fi
    fi

    wDetail "${detail}" network_io

    if [ "$issues" -ge 2 ]; then
        wResult "ERROR" network_io
    elif [ "$issues" -eq 1 ]; then
        wResult "WARNING" network_io
    else
        wResult "NORMAL" network_io
    fi
}

# ---- 主机连通性检查 (支持多节点) ----
check_host_connectivity() {
    local detail=""
    detail+="===== 主机连通性检查 =====\n\n"

    # 从 PG 配置中解析节点列表
    local nodes=""
    # 1. 从流复制获取 standby 地址
    local standby_addrs
    standby_addrs=$(sql_exec "SELECT client_addr FROM pg_stat_replication WHERE state='streaming'" 2>/dev/null | sort -u)
    detail+="--- 备库节点 ---\n${standby_addrs:-无备库连接}\n\n"

    # 2. 从 recovery.conf / postgresql.auto.conf 获取 primary (如果是备库)
    local is_standby; is_standby=$(sql_exec "SELECT pg_is_in_recovery()" 2>/dev/null || echo "t")
    if [ "$is_standby" = "t" ]; then
        local primary_info
        primary_info=$(sql_exec "SELECT conninfo FROM pg_stat_wal_receiver" 2>/dev/null || echo "")
        local primary_host
        primary_host=$(echo "$primary_info" | grep -oP 'host=\K[^\s]+' 2>/dev/null || echo "")
        detail+="--- 主库节点 ---\nprimary_host=${primary_host}\n\n"
        nodes="${nodes}${primary_host}\n"
    fi
    nodes="${nodes}${standby_addrs}"

    # 3. 如果提供了 HOST_NODES 环境变量，追加
    if [ -n "${HOST_NODES:-}" ]; then
        nodes="${nodes}${HOST_NODES}\n"
    fi

    # 去重
    nodes=$(echo "$nodes" | sort -u | grep -v '^$')

    if [ -z "$nodes" ]; then
        detail+="未检测到需要检查的远程节点 (单机部署)\n"
        wDetail "${detail}" host_connectivity
        wResult "INFO" host_connectivity
        return
    fi

    # 4. 并行 ping 探测
    detail+="--- 连通性探测 (ping) ---\n"
    local tmpfile; tmpfile=$(mktemp /tmp/pgcheck_ping.XXXXXX)
    local node_count=0

    while IFS= read -r node; do
        [ -z "$node" ] && continue
        node_count=$((node_count+1))
        (
            if ping -c 2 -W 2 "$node" >/dev/null 2>&1; then
                local rtt; rtt=$(ping -c 2 -W 2 "$node" 2>/dev/null | tail -1 | awk -F'/' '{print $5}')
                echo "$node: OK (rtt=${rtt:-N/A}ms)" >> "$tmpfile"
            else
                echo "$node: FAIL" >> "$tmpfile"
            fi
        ) &
    done <<EOF
$nodes
EOF
    wait
    detail+="探测节点数: ${node_count}\n"
    detail+="$(cat "$tmpfile" 2>/dev/null)\n"
    local fail_count; fail_count=$(grep -c "FAIL" "$tmpfile" 2>/dev/null || echo "0")
    rm -f "$tmpfile"

    # 5. TCP 端口探测
    detail+="\n--- 数据库端口连通性 (${PGPORT}) ---\n"
    while IFS= read -r node; do
        [ -z "$node" ] && continue
        if timeout 3 bash -c "echo >/dev/tcp/${node}/${PGPORT}" 2>/dev/null; then
            detail+="$node:${PGPORT} OK\n"
        else
            detail+="$node:${PGPORT} FAIL\n"
            fail_count=$((fail_count+1))
        fi
    done <<EOF
$nodes
EOF

    wDetail "${detail}" host_connectivity

    if [ "$fail_count" -gt 0 ]; then
        wResult "ERROR" host_connectivity
    else
        wResult "NORMAL" host_connectivity
    fi
}

# ---- 登录失败检测 (二次采样对比) ----
check_login_failures() {
    local detail=""
    detail+="===== 登录失败检测 (二次采样, 窗口=${LOGIN_FAIL_WINDOW}s) =====\n\n"
    local issues=0

    # 1. PG 日志中的认证失败 (第一次采样)
    local log_dir; log_dir=$(sql_exec "SELECT setting FROM pg_settings WHERE name='log_directory'" 2>/dev/null || echo "pg_log")
    local log_path=""
    [ -d "$DB_LOG_DIR/$log_dir" ] && log_path="$DB_LOG_DIR/$log_dir"
    [ -d "$PGDATA/$log_dir" ] && log_path="$PGDATA/$log_dir"

    if [ -z "$log_path" ]; then
        detail+="无法定位 PG 日志目录，跳过登录失败检测\n"
        wDetail "${detail}" login_failures
        wResult "UNKOWN" login_failures
        return
    fi

    local fail1
    fail1=$(grep -rE "FATAL.*(password authentication|no pg_hba)" "$log_path" 2>/dev/null | wc -l || echo "0")
    detail+="第一次采样 (当前日志累计): 认证失败 ${fail1} 次\n"

    # 2. 等待采样窗口
    detail+="等待 ${LOGIN_FAIL_WINDOW} 秒进行二次采样...\n"
    sleep "${LOGIN_FAIL_WINDOW}"

    local fail2
    fail2=$(grep -rE "FATAL.*(password authentication|no pg_hba)" "$log_path" 2>/dev/null | wc -l || echo "0")
    detail+="第二次采样: 认证失败 ${fail2} 次\n"

    local fail_diff=$((fail2 - fail1))
    detail+="增量: ${fail_diff} 次\n"

    if [ "$fail_diff" -lt 0 ]; then
        # 日志可能被轮转
        detail+="注意: 增量异常(负数)，可能是日志轮转导致，无法判断\n"
        wDetail "${detail}" login_failures
        wResult "UNKOWN" login_failures
        return
    fi

    detail+="\n--- 最近的认证失败日志 (前10条) ---\n"
    local recent_fails
    recent_fails=$(grep -rE "FATAL.*(password authentication|no pg_hba)" "$log_path" 2>/dev/null | tail -10 || echo "无")
    detail+="${recent_fails}\n"

    # 3. 数据库用户锁定状态
    detail+="\n--- 可能被锁定的用户 ---\n"
    local locked_users
    locked_users=$(sql_exec "SELECT rolname, rolvaliduntil
        FROM pg_authid
        WHERE rolvaliduntil IS NOT NULL
        AND rolvaliduntil > now()
        AND rolcanlogin = true
        ORDER BY rolvaliduntil
        LIMIT 10" 2>/dev/null || echo "无")
    detail+="${locked_users}\n"

    wDetail "${detail}" login_failures

    if [ "$fail_diff" -gt 20 ]; then
        wResult "ERROR" login_failures
        detail+="警告: 在 ${LOGIN_FAIL_WINDOW}s 内有 ${fail_diff} 次新认证失败，可能存在暴力破解！\n"
    elif [ "$fail_diff" -gt 5 ]; then
        wResult "WARNING" login_failures
    elif [ "$fail_diff" -gt 0 ]; then
        wResult "INFO" login_failures
    else
        wResult "NORMAL" login_failures
    fi
}

# ---- 备份深度检查 ----
check_backup_depth() {
    local detail=""
    detail+="===== 备份深度检查 (阈值: ${BACKUP_STALE_HOURS}h) =====\n\n"
    local issues=0

    # 1. 归档状态 (pg_stat_archiver)
    detail+="--- 归档状态 ---\n"
    local arch_last; arch_last=$(sql_exec "SELECT last_archived_time FROM pg_stat_archiver" 2>/dev/null || echo "")
    if [ -n "$arch_last" ] && [ "$arch_last" != "" ]; then
        local arch_sec_ago
        arch_sec_ago=$(sql_exec "SELECT EXTRACT(epoch FROM now() - last_archived_time)::int FROM pg_stat_archiver WHERE last_archived_time IS NOT NULL" 2>/dev/null || echo "0")
        detail+="最后归档时间: ${arch_last} (${arch_sec_ago}s 前)\n"
        if [ "${arch_sec_ago:-0}" -gt "$((BACKUP_STALE_HOURS * 3600))" ] 2>/dev/null; then
            detail+="警告: 超过 ${BACKUP_STALE_HOURS}h 无归档！\n"
            issues=$((issues+1))
        fi
    else
        detail+="无归档记录 (可能未开启 archive_mode)\n"
    fi

    # 2. 查找最近的物理备份文件
    detail+="\n--- 物理备份文件检查 ---\n"
    local backup_files_found=0
    for bdir in "${BACKUP_DIR}" /data/backup /backup /opt/backup; do
        if [ -d "$bdir" ]; then
            local recent_bk
            recent_bk=$(find "$bdir" -maxdepth 3 \( -name "*.dump" -o -name "*.tar.gz" -o -name "*.sql.gz" -o -name "*.sql" -o -name "*.backup" \) -mtime -"$((BACKUP_STALE_HOURS / 24))" 2>/dev/null | head -20)
            if [ -n "$recent_bk" ]; then
                detail+="目录: ${bdir}\n"
                local bk_list
                bk_list=$(echo "$recent_bk" | while read -r f; do
                    local sz; sz=$(du -sh "$f" 2>/dev/null | awk '{print $1}')
                    local mt; mt=$(stat -c "%Y" "$f" 2>/dev/null || stat -f "%m" "$f" 2>/dev/null)
                    echo "  $(date -r "$mt" '+%Y-%m-%d %H:%M' 2>/dev/null) ${sz} ${f}"
                done)
                detail+="${bk_list}\n"
                backup_files_found=$((backup_files_found + $(echo "$recent_bk" | wc -l)))
            fi
        fi
    done

    if [ "$backup_files_found" -eq 0 ]; then
        detail+="未找到 ${BACKUP_STALE_HOURS}h 内的备份文件！\n"
        issues=$((issues+1))
    else
        detail+="找到 ${backup_files_found} 个备份文件\n"
    fi

    # 3. 检查 cron 中的备份任务
    detail+="\n--- 定时备份任务 ---\n"
    local cron_backup_tasks
    cron_backup_tasks=$(crontab -l 2>/dev/null | grep -v '^#' | grep -iE "backup|dump|pg_dump|pg_basebackup|pgbackrest|pg_probackup|barman|wal-g" || echo "无")
    detail+="${cron_backup_tasks}\n"

    # 4. pg_stat_progress_basebackup (PG13+)
    local bb_running
    bb_running=$(sql_exec "SELECT count(*) FROM pg_stat_progress_basebackup" 2>/dev/null || echo "0")
    if [ "$bb_running" -gt 0 ]; then
        detail+="\n当前正在执行的 basebackup: ${bb_running} 个\n"
    fi

    wDetail "${detail}" backup_depth

    if [ "$issues" -ge 2 ]; then
        wResult "ERROR" backup_depth
    elif [ "$issues" -eq 1 ]; then
        wResult "WARNING" backup_depth
    else
        wResult "NORMAL" backup_depth
    fi
}

# ---- 表膨胀深度检查 ----
check_db_bloat() {
    local detail=""
    detail+="===== 表 & 索引膨胀深度检查 =====\n\n"
    local issues=0

    # 1. 死元组统计 (按库分组)
    local dead_tup_by_db
    dead_tup_by_db=$(sql_table "SELECT
        datname,
        sum(n_dead_tup)::bigint AS total_dead,
        count(*) AS table_count
    FROM pg_stat_user_tables
    JOIN pg_database d ON d.datname = current_database()
    WHERE n_dead_tup > 0
    GROUP BY datname
    ORDER BY total_dead DESC;" 2>/dev/null)
    detail+="--- 死元组统计 (当前库) ---\n${dead_tup_by_db:-无数据}\n\n"

    # 2. Top 20 死元组最多的表
    detail+="--- Top 20 死元组最多的表 ---\n"
    local dead_top
    dead_top=$(sql_table "SELECT
        schemaname || '.' || relname AS table_name,
        n_dead_tup,
        n_live_tup,
        CASE WHEN n_live_tup > 0
            THEN round(100.0 * n_dead_tup / (n_live_tup + n_dead_tup), 1)
            ELSE 0 END AS dead_pct,
        last_vacuum,
        last_autovacuum
    FROM pg_stat_user_tables
    WHERE n_dead_tup > 1000
    ORDER BY n_dead_tup DESC
    LIMIT 20;" 2>/dev/null)
    detail+="${dead_top}\n\n"

    # 3. 高死元组占比的表 (dead_pct > 30%)
    local high_dead_count
    high_dead_count=$(sql_exec "SELECT count(*) FROM pg_stat_user_tables
        WHERE n_live_tup + n_dead_tup > 0
        AND round(100.0 * n_dead_tup / (n_live_tup + n_dead_tup), 1) > 30" 2>/dev/null || echo "0")
    detail+="死元组占比 > 30% 的表: ${high_dead_count} 张\n"

    if [ "$high_dead_count" -gt 10 ]; then
        detail+="警告: 大量表死元组占比过高，建议检查 autovacuum 配置\n"
        issues=$((issues+2))
    elif [ "$high_dead_count" -gt 0 ]; then
        detail+="注意: 存在死元组占比 > 30% 的表\n"
        issues=$((issues+1))
    fi

    # 4. 膨胀索引 Top 10
    detail+="\n--- Top 10 疑似膨胀的 B-tree 索引 ---\n"
    local idx_bloat
    idx_bloat=$(sql_table "SELECT
        n.nspname || '.' || c.relname AS index_name,
        pg_size_pretty(pg_relation_size(i.indexrelid)) AS index_size,
        idx_scan,
        idx_tup_read,
        idx_tup_fetch
    FROM pg_stat_user_indexes i
    JOIN pg_class c ON c.oid = i.indexrelid
    JOIN pg_namespace n ON n.oid = c.relnamespace
    WHERE idx_scan > 0
    AND pg_relation_size(i.indexrelid) > 104857600
    ORDER BY pg_relation_size(i.indexrelid) DESC
    LIMIT 10;" 2>/dev/null)
    detail+="${idx_bloat:-无大索引}\n"

    wDetail "${detail}" db_bloat

    if [ "$issues" -ge 2 ]; then
        wResult "ERROR" db_bloat
    elif [ "$issues" -eq 1 ]; then
        wResult "WARNING" db_bloat
    else
        wResult "NORMAL" db_bloat
    fi
}

#################### HTML 报告生成 ####################
#################### Schema 健康检查 (pg-index-health-sql) ####################
# 改编自 https://github.com/mfvanek/pg-index-health-sql
SCHEMA_SQL="${0%/*}/mm_pg_schema_health.sql"
SCHEMA_CHECKS="invalid_indexes unused_indexes duplicated_indexes intersected_indexes idx_null_values idx_boolean btree_array_idx idx_unnecessary_where idx_timestamp_not_last idx_bloat fk_no_index dup_foreign_keys intersected_fkeys fk_type_mismatch fk_null_values self_ref_fkeys not_valid_constraints no_pk_tables missing_indexes table_bloat table_inheritance zero_one_col_tables pk_not_first_col all_nullable_except_pk unlinked_tables empty_tables seq_overflow json_type_cols serial_type_cols fixed_varchar_cols money_type_cols timestamp_tz_cols char_type_cols blob_type_cols serial_pk varchar_pk natural_pk no_table_desc no_col_desc no_func_desc obj_naming col_naming obj_name_overflow"

check_schema_health() {
    local schema_name="${1:-public}"
    local sql_dir; sql_dir="$(dirname "$0")"
    local sql_file="${sql_dir}/mm_pg_schema_health.sql"

    if [ ! -f "$sql_file" ]; then
        echo "WARNING: Schema health SQL file not found: $sql_file"
        for chk in $SCHEMA_CHECKS; do
            wResult "UNKOWN" "schema_${chk}"
            wDetail "SQL file not found: $sql_file" "schema_${chk}"
        done
        return
    fi

    # Run the SQL file against the database
    local sql_output
    if [ "$PG_VARIANT" = "opengauss" ] || [ "$PG_VARIANT" = "vastbase" ]; then
        sql_output=$(gsql -W "${PGPASSWORD}" --pset=pager=off -q \
            -v schema_name="'${schema_name}'" \
            -v seq_threshold=10 \
            -f "$sql_file" 2>/dev/null)
    else
        sql_output=$(psql -h "${PGHOST}" -p "${PGPORT}" -U "${PGUSER}" -d "${PGDATABASE}" -q \
            -v schema_name="'${schema_name}'" \
            -v seq_threshold=10 \
            -f "$sql_file" 2>/dev/null)
    fi

    # 定义检查项: label key section_marker
    local checks="
invalid_indexes:1.无效索引
unused_indexes:2.未使用的索引
duplicated_indexes:3.完全重复索引
intersected_indexes:4.交叉(部分重叠)索引
idx_null_values:5.含NULL值列的索引
idx_boolean:6.含布尔类型列的索引
btree_array_idx:7.数组列上的B-tree索引
idx_unnecessary_where:8.含不必要WHERE子句的索引
idx_timestamp_not_last:9.时间戳列不在索引末尾
idx_bloat:10.B-tree索引膨胀
fk_no_index:11.外键缺少索引
dup_foreign_keys:12.完全重复外键
intersected_fkeys:13.交叉(部分重叠)外键
fk_type_mismatch:14.外键列类型不匹配
fk_null_values:15.外键含NULL值
self_ref_fkeys:16.自引用外键
not_valid_constraints:17.未验证的约束
no_pk_tables:18.无主键的表
missing_indexes:19.缺少索引的表
table_bloat:20.表膨胀
table_inheritance:21.使用继承的表
zero_one_col_tables:22.只有0或1列的表
pk_not_first_col:23.主键列不在第一列
all_nullable_except_pk:24.非主键列全为NULL
unlinked_tables:25.未与其他表关联的表
empty_tables:26.无数据的表
seq_overflow:27.序列溢出风险
json_type_cols:28.使用json类型的列
serial_type_cols:29.使用serial类型的非主键列
fixed_varchar_cols:30.使用定长varchar(n)的列
money_type_cols:31.使用money类型的列
timestamp_tz_cols:32.使用timestamp(无时区)的列
char_type_cols:33.使用char(n)类型的列
blob_type_cols:34.使用大对象类型的列
serial_pk:35.使用serial类型的主键
varchar_pk:36.使用varchar作为主键
natural_pk:37.疑似自然主键(非UUID)
no_table_desc:38.缺少COMMENT描述的表
no_col_desc:39.缺少COMMENT描述的列
no_func_desc:40.缺少COMMENT描述的函数
obj_naming:41.对象名不符合命名规范
col_naming:42.列名不符合命名规范
obj_name_overflow:43.对象名称可能溢出
"

    while IFS=: read -r key label; do
        [ -z "$key" ] && continue
        local section_num; section_num=$(echo "$label" | cut -d'.' -f1)

        # 提取对应 section 的输出
        local section_output
        section_output=$(echo "$sql_output" | awk "/\[${section_num}\//{flag=1; next} /\[$(($section_num + 1))\/|Schema 健康检查完成|Schema 健康检查/"'/{flag=0} flag' 2>/dev/null)

        # 统计行数 (跳过空行、表头、分隔线)
        local data_lines
        data_lines=$(echo "$section_output" | grep -v '^\s*$' | grep -v '^--' | grep -v 'table_name' | grep -v 'rows*)$' | wc -l)

        wDetail "$section_output" "schema_${key}"

        # 判定: 有数据行 = WARNING, 无数据 = NORMAL
        if [ "$data_lines" -gt 0 ]; then
            wResult "WARNING" "schema_${key}"
        else
            wResult "NORMAL" "schema_${key}"
        fi
    done <<EOF
$checks
EOF
}

write_html_header() {
    cat >> "$FILE_OUTPUT" << 'HTMLEOF'
<!DOCTYPE html>
<html lang="zh-CN">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width, initial-scale=1.0">
<title>木木 PG 健康巡检报告</title>
<style>
  :root {
    --bg: #0f172a; --card-bg: #1e293b; --text: #e2e8f0;
    --text-secondary: #94a3b8; --primary: #3b82f6; --success: #22c55e;
    --warning: #f59e0b; --error: #ef4444; --fatal: #dc2626;
    --border: #334155; --hover: #475569;
  }
  * { margin: 0; padding: 0; box-sizing: border-box; }
  body { font: 14px "Microsoft YaHei", sans-serif; background: var(--bg); color: var(--text); line-height: 1.6; }
  .header { background: linear-gradient(135deg, #1e3a5f 0%, #0f172a 100%); padding: 32px 48px; border-bottom: 3px solid var(--primary); }
  .header h1 { font-size: 28px; color: #fff; margin-bottom: 8px; }
  .header .meta { font-size: 14px; color: var(--text-secondary); }
  .container { max-width: 1200px; margin: 0 auto; padding: 24px; }
  .dashboard { display: grid; grid-template-columns: repeat(auto-fit, minmax(200px, 1fr)); gap: 16px; margin-bottom: 32px; }
  .dash-card { background: var(--card-bg); border-radius: 12px; padding: 20px; text-align: center; border: 1px solid var(--border); }
  .dash-card .count { font-size: 36px; font-weight: 700; margin-bottom: 4px; }
  .dash-card .label { font-size: 13px; color: var(--text-secondary); }
  .count-fatal { color: var(--fatal); }
  .count-error { color: var(--error); }
  .count-warning { color: var(--warning); }
  .count-normal { color: var(--success); }
  .section { background: var(--card-bg); border-radius: 12px; padding: 24px; margin-bottom: 24px; border: 1px solid var(--border); }
  .section h2 { font-size: 20px; color: var(--primary); margin-bottom: 16px; padding-bottom: 8px; border-bottom: 1px solid var(--border); display: flex; align-items: center; gap: 8px; }
  .section h2 .badge { font-size: 12px; padding: 2px 8px; border-radius: 12px; }
  .badge-os { background: #3b82f633; color: #60a5fa; }
  .badge-db { background: #22c55e33; color: #4ade80; }
  .badge-sec { background: #f59e0b33; color: #fbbf24; }
  .badge-param { background: #a855f733; color: #c084fc; }
  .badge-schema { background: #ec489933; color: #f472b6; }
  table { width: 100%; border-collapse: collapse; font-size: 13px; }
  th { background: var(--border); color: var(--text); font-weight: 600; padding: 10px 12px; text-align: left; }
  td { padding: 10px 12px; border-bottom: 1px solid var(--border); }
  tr:hover { background: var(--hover); }
  .status { display: inline-block; padding: 3px 10px; border-radius: 12px; font-size: 12px; font-weight: 600; }
  .status-FATAL { background: #dc262633; color: #fca5a5; }
  .status-ERROR { background: #ef444433; color: #fca5a5; }
  .status-WARNING { background: #f59e0b33; color: #fde68a; }
  .status-NORMAL { background: #22c55e33; color: #86efac; }
  .status-PASS { background: #22c55e33; color: #86efac; }
  .status-INFO { background: #3b82f633; color: #93c5fd; }
  .status-UNKOWN { background: #64748b33; color: #cbd5e1; }
  .collapsible { cursor: pointer; user-select: none; }
  .collapsible::before { content: "▸ "; display: inline-block; transition: transform 0.2s; }
  .collapsible.open::before { transform: rotate(90deg); }
  .detail-content { display: none; background: #0f172a; border-radius: 8px; padding: 12px 16px; margin-top: 8px; white-space: pre-wrap; font-size: 12px; font-family: "Courier New", monospace; max-height: 400px; overflow-y: auto; }
  .detail-content.open { display: block; }
  .summary-bar { display: flex; gap: 12px; margin-bottom: 16px; flex-wrap: wrap; font-size: 13px; }
  .summary-item { display: flex; align-items: center; gap: 4px; }
  .footer { text-align: center; padding: 24px; color: var(--text-secondary); font-size: 12px; }
  .recommendation { background: #3b82f611; border-left: 3px solid var(--primary); padding: 12px 16px; margin-top: 12px; border-radius: 4px; font-size: 13px; }
  @media (max-width: 768px) { .container { padding: 12px; } .header { padding: 24px; } }
</style>
<script>
function toggleDetail(id) {
  var el = document.getElementById(id);
  el.classList.toggle('open');
  var btn = el.previousElementSibling;
  if (btn) btn.classList.toggle('open');
}
</script>
</head>
<body>
HTMLEOF
}

write_html_body_start() {
    cat >> "$FILE_OUTPUT" << HTMLEOF
<div class="header">
  <h1>🩺 木木 PG 健康巡检报告</h1>
  <div class="meta">
    <div>巡检时间: $(date "+%Y-%m-%d %H:%M:%S")</div>
    <div>主机: ${MYHOST} | DB端口: ${PGPORT} | 变体: ${PG_VARIANT^^}</div>
  </div>
</div>
<div class="container">
HTMLEOF
}

write_dashboard() {
    local fatal_cnt;   fatal_cnt=$(grep -c "FATAL"   "${RESULT_DIR}"/*_result 2>/dev/null || echo 0)
    local error_cnt;   error_cnt=$(grep -c "ERROR"   "${RESULT_DIR}"/*_result 2>/dev/null || echo 0)
    local warn_cnt;    warn_cnt=$(grep -c "WARNING"  "${RESULT_DIR}"/*_result 2>/dev/null || echo 0)
    local normal_cnt;  normal_cnt=$(grep -cE "NORMAL|PASS" "${RESULT_DIR}"/*_result 2>/dev/null || echo 0)
    local total;       total=$((fatal_cnt + error_cnt + warn_cnt + normal_cnt))
    local grade=""
    if [ "$fatal_cnt" -gt 0 ]; then
        grade="⚠️ 需紧急处理: 存在 FATAL 项"
    elif [ "$error_cnt" -gt 2 ]; then
        grade="🔴 较差: 存在 ${error_cnt} 个 ERROR"
    elif [ "$error_cnt" -gt 0 ]; then
        grade="🟡 一般: 存在 ${error_cnt} 个 ERROR"
    elif [ "$warn_cnt" -gt 3 ]; then
        grade="🟡 一般: ${warn_cnt} 个 WARNING"
    else
        grade="🟢 健康"
    fi

    cat >> "$FILE_OUTPUT" << HTMLEOF
<div class="dashboard">
  <div class="dash-card"><div class="count count-fatal">${fatal_cnt}</div><div class="label">FATAL</div></div>
  <div class="dash-card"><div class="count count-error">${error_cnt}</div><div class="label">ERROR</div></div>
  <div class="dash-card"><div class="count count-warning">${warn_cnt}</div><div class="label">WARNING</div></div>
  <div class="dash-card"><div class="count count-normal">${normal_cnt}</div><div class="label">NORMAL</div></div>
</div>
<div class="summary-bar">
  <div class="summary-item">总计: <strong>${total}</strong> 项</div>
  <div class="summary-item">综合评级: <strong>${grade}</strong></div>
</div>
HTMLEOF
}

write_check_section() {
    local title="$1"
    local badge="$2"
    local prefix="$3"
    local keys="$4"

    cat >> "$FILE_OUTPUT" << HTMLEOF
<div class="section">
  <h2>${title} <span class="badge badge-${badge}">${badge^^}</span></h2>
  <table>
    <tr><th>检查项</th><th>状态</th><th>详情</th></tr>
HTMLEOF

    for key in $keys; do
        local key_clean; key_clean=$(echo "$key" | sed 's/[[:space:]]//g')
        local status; status=$(read_result "$key_clean")
        local detail_file="${RESULT_DIR}/${key_clean}_detail"
        local has_detail=""
        [ -s "$detail_file" ] && has_detail="yes"

        local display_name; display_name=$(echo "$key_clean" | sed 's/_/ /g')

        if [ "$has_detail" = "yes" ]; then
            cat >> "$FILE_OUTPUT" << HTMLEOF
    <tr>
      <td>${display_name}</td>
      <td><span class="status status-${status}">${status}</span></td>
      <td><span class="collapsible" onclick="toggleDetail('det_${key_clean}')">展开</span>
        <div class="detail-content" id="det_${key_clean}">$(sed 's/</\&lt;/g; s/>/\&gt;/g' "$detail_file")</div>
      </td>
    </tr>
HTMLEOF
        else
            cat >> "$FILE_OUTPUT" << HTMLEOF
    <tr>
      <td>${display_name}</td>
      <td><span class="status status-${status}">${status}</span></td>
      <td>-</td>
    </tr>
HTMLEOF
        fi
    done

    echo "</table></div>" >> "$FILE_OUTPUT"
}

write_html_footer() {
    local total_good; total_good=$(grep -cE "NORMAL|PASS" "${RESULT_DIR}"/*_result 2>/dev/null || echo 0)
    local total_all;  total_all=$(find "${RESULT_DIR}" -name "*_result" | wc -l)

    cat >> "$FILE_OUTPUT" << HTMLEOF
<div class="section">
  <h2>📋 整改建议</h2>
  <p style="color:var(--text-secondary)">以下为基于木木武器库的自动整改建议，请结合实际业务审慎评估后逐步实施。</p>
  <div class="recommendation">
    <strong>参数调优（武器库 5.1）：</strong><br>
    • 使用 shared_buffers=内存×0.25 (不超过32GB)<br>
    • work_mem 建议 4-64MB (按业务 SQL 调整)<br>
    • effective_cache_size=内存×0.75<br>
    • checkpoint_timeout≥15min, wal_compression=on<br>
    • autovacuum_max_workers=max(min(8, CPU/2), 5)<br>
    • 监控 XID/MXID 年龄: age(datfrozenxid)&lt;1.5亿, mxid_age(datminmxid)&lt;3亿
  </div>
  <div class="recommendation" style="margin-top:16px">
    <strong>安全加固（武器库 6.2）：</strong><br>
    • 全部密码使用 SCRAM-SHA-256, password_encryption='scram-sha-256'<br>
    • 撤销 PUBLIC schema CREATE 权限: REVOKE CREATE ON SCHEMA public FROM PUBLIC<br>
    • 审查 SECURITY DEFINER 函数, 敏感表启用 RLS<br>
    • 生产环境启用 pgaudit: log='ddl,write,role'<br>
    • SSL=on, 使用客户端证书认证
  </div>
  <div class="recommendation" style="margin-top:16px">
    <strong>Schema 结构优化（pg-index-health-sql）：</strong><br>
    • 删除重复/重叠索引降低写开销<br>
    • 为外键列创建索引避免全表扫描<br>
    • 每张表都应有主键<br>
    • 监控序列溢出风险，适时升级为 bigserial<br>
    • 定期检查未验证约束 (NOT VALID) 的状态<br>
    • 监控表/索引膨胀率 (基于 pg_stats 估算)，超过 30% 建议 VACUUM FULL 或 pg_repack
  </div>
  <div class="recommendation" style="margin-top:16px">
    <strong>阻塞 & 慢SQL & 长事务处理：</strong><br>
    • 终止问题会话: SELECT pg_terminate_backend(pid)<br>
    • 设置语句超时: statement_timeout='30s', idle_in_transaction_session_timeout='10min'<br>
    • 审查锁持有者: 检查是否有未提交事务持有排他锁<br>
    • 慢SQL优化: 使用 EXPLAIN (ANALYZE, BUFFERS) 分析执行计划<br>
    • 大表 VACUUM: 表膨胀 > 30% 考虑 VACUUM FULL 或 pg_repack<br>
    • 深入诊断: ./mm_pg_diag.sh --host HOST --port PORT --type slow_sql|blocking|long_txn|bloat
  </div>
  <div class="recommendation" style="margin-top:16px">
    <strong>网络 & 安全 & 备份（v2.0 新增）：</strong><br>
    • 网卡丢包 > 阈值，检查交换机/网卡/Ring Buffer 大小<br>
    • TCP 重传过多，检查防火墙/MTU/网络拥塞<br>
    • 登录失败频繁：审查 pg_hba.conf、启用 pgaudit、考虑 fail2ban<br>
    • 备份超期：定期 pg_dump/pg_basebackup + 异地存储 + 恢复演练<br>
    • 复制延迟过大：检查备库 IO、增大 max_wal_size、审查 WAL 发送/接收
  </div>
</div>
</div>
<div class="footer">
  木木 PG 健康巡检 v2.2 | $(date "+%Y-%m-%d %H:%M:%S") | ${PG_VARIANT}
</div>
</body>
</html>
HTMLEOF
}

#################### 主流程 ####################
main() {
    echo "🩺 木木 PG 健康巡检 v2.0"
    echo "=================================="

    # 变体检测
    detect_variant
    echo "  检测到数据库变体: ${PG_VARIANT^^}"

    # ===== 系统信息 =====
    echo "[1/4] 收集系统信息..."
    get_os_info

    # ===== OS 巡检 =====
    echo "[2/4] 执行 OS 层巡检..."
    check_os_user_expiry &
    check_kernel_params &
    check_resource_limits &
    check_selinux &
    check_transparent_hugepage &
    check_af_alg &
    check_cpu_usage &
    check_memory_usage &
    check_disk_usage &
    check_syslog_errors &
    check_cron_backup &
    check_host_uptime &
    check_network_io &
    check_host_connectivity &
    check_login_failures &
    check_file_descriptors &
    wait

    # ===== 数据库巡检 =====
    echo "[3/4] 执行数据库层巡检..."
    check_db_version &
    check_db_connections &
    check_db_replication &
    check_db_archive &
    check_db_autovacuum &
    check_db_xid_mxid &
    check_db_locks &
    check_db_tablespace &
    check_db_log_errors &
    check_db_logical_replication &
    check_db_data_sync_retry &
    check_db_collation &
    check_db_checkpoint &
    check_db_bgwriter &
    check_db_slru &
    check_db_external_calls &
    check_db_stat_health &
    check_guc_tuning_sanities &
    check_partition_config &
    check_query_id_chain &
    check_pgss_deep &
    check_db_slow_sql &
    check_db_long_txn &
    check_db_blocking &
    check_db_data_checksums &
    wait
    check_param_formulas
    check_security
    check_backup_depth
    check_db_bloat

    # ===== Schema 结构健康 =====
    echo "[3.5/4] 执行 Schema 结构健康检查..."
    check_schema_health "public"

    # ===== 生成报告 =====
    echo "[4/4] 生成 HTML 报告..."
    write_html_header
    write_html_body_start
    write_dashboard

    # OS 检查项
    write_check_section "📊 操作系统巡检" "os" "os_" \
      "os_user_expire kernel_params resource_limits selinux transparent_hugepage af_alg cpu_usage memory_usage disk_usage syslog_errors cron_backup host_uptime network_io host_connectivity login_failures file_descriptors"

    # 数据库检查项
    write_check_section "🗄️ 数据库巡检" "db" "db_" \
      "db_version db_connections db_replication db_archive db_autovacuum db_xid_mxid db_locks db_tablespace db_log_errors db_logical_replication db_data_sync_retry db_collation db_checkpoint db_bgwriter db_slru db_external_calls db_stat_health guc_tuning_sanities partition_config query_id_chain pgss_deep db_slow_sql db_long_txn db_blocking db_data_checksums backup_depth db_bloat"

    # 参数公式验证
    write_check_section "📐 参数公式验证 (武器库 5.1)" "param" "param_" \
      "param_formulas"

    # 安全检查
    write_check_section "🔐 安全加固 Checklist (武器库 6.2)" "sec" "sec_" \
      "security_checklist"

    # Schema 结构健康
    write_check_section "🔍 Schema 结构健康 (pg-index-health-sql)" "schema" "schema_" \
      "schema_invalid_indexes schema_unused_indexes schema_duplicated_indexes schema_intersected_indexes schema_idx_null_values schema_idx_boolean schema_btree_array_idx schema_idx_unnecessary_where schema_idx_timestamp_not_last schema_idx_bloat schema_fk_no_index schema_dup_foreign_keys schema_intersected_fkeys schema_fk_type_mismatch schema_fk_null_values schema_self_ref_fkeys schema_not_valid_constraints schema_no_pk_tables schema_missing_indexes schema_table_bloat schema_table_inheritance schema_zero_one_col_tables schema_pk_not_first_col schema_all_nullable_except_pk schema_unlinked_tables schema_empty_tables schema_seq_overflow schema_json_type_cols schema_serial_type_cols schema_fixed_varchar_cols schema_money_type_cols schema_timestamp_tz_cols schema_char_type_cols schema_blob_type_cols schema_serial_pk schema_varchar_pk schema_natural_pk schema_no_table_desc schema_no_col_desc schema_no_func_desc schema_obj_naming schema_col_naming schema_obj_name_overflow"

    write_html_footer

    echo ""
    echo "=================================="
    echo "✅ 巡检完成！"
    echo "📄 报告: ${FILE_OUTPUT}"
    echo "📁 详情: ${RESULT_DIR}/"
    echo "=================================="
}

main "$@"
