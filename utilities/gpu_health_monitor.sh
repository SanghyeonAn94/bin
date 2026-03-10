#!/bin/bash
set -euo pipefail

# Slack : incoming-webhook App
# SLACK_WEBHOOK_URL must be set as an environment variable
SLACK_WEBHOOK_URL="${SLACK_WEBHOOK_URL:?'SLACK_WEBHOOK_URL is not set'}"
HOSTNAME=$(hostname -I | awk '{print $1}')

# Max GPU Temperature Threshold
THRESHOLD_GPU_TEMP=75 # GPU core (value shown in nvidia-smi)
THRESHOLD_MEM_TEMP=85 # GPU memory (HBM temperature)

# THRESHOLD_GPU_TEMP=50 # GPU core (value shown in nvidia-smi)
# THRESHOLD_MEM_TEMP=60 # GPU memory (HBM temperature)

# Inlet Temperature Thresholds
THRESHOLD_INLET_TEMP=30
THRESHOLD_HGX_INLET_TEMP=40

# GPU Temperature Violation Tracking (consecutive violations trigger process kill)
GPU_TEMP_VIOLATION_COUNT_FILE="/tmp/gpu_temp_violation_count"
GPU_TEMP_VIOLATION_THRESHOLD=3

# Capture timestamp at script start
TIMESTAMP=$(TZ='Asia/Seoul' date '+%Y-%m-%d %H:%M:%S')

send_slack_alert() {
    local level="$1"
    local message="$2"
    local color="#ff0000"
    if [[ "$level" == "WARNING" ]]; then
        color="#ffcc00"
    fi
    local payload="{\"attachments\":[{\"color\":\"${color}\",\"title\":\"[${TIMESTAMP}] [${level}] Alert - IP : ${HOSTNAME}\",\"text\":\"${message}\",\"ts\":$(date +%s)}]}"
    curl -s -X POST -H 'Content-type: application/json' --data "${payload}" "${SLACK_WEBHOOK_URL}" > /dev/null 2>&1 || true
}

check_threshold() {
    local val="$1"
    local thresh="$2"
    local cmp="$3"
    if [[ "$val" == "N/A" || -z "$val" || "$val" == "[N/A]" || "$val" == "[Not Supported]" ]]; then
        return 1
    fi
    val=$(echo "$val" | tr -d ' ')
    case "$cmp" in
        gt) [[ "$val" -gt "$thresh" ]] && return 0 ;;
        eq) [[ "$val" -eq "$thresh" ]] && return 0 ;;
        ne) [[ "$val" -ne 0 ]] && return 0 ;;
    esac
    return 1
}

main() {
    local alerts_critical=""
    local alerts_warning=""

    # nvidia-smi로 온도 데이터 수집
    local temp_output
    temp_output=$(nvidia-smi --query-gpu=index,temperature.gpu,temperature.memory --format=csv,noheader,nounits 2>/dev/null) || {
        echo "ERROR: nvidia-smi execution failed"
        exit 1
    }

    local gpu_temp_violated=false

    while IFS=, read -r gpu_id gpu_temp mem_temp; do
        gpu_id=$(echo "$gpu_id" | tr -d ' ')
        gpu_temp=$(echo "$gpu_temp" | tr -d ' ')
        mem_temp=$(echo "$mem_temp" | tr -d ' ')

        if check_threshold "$gpu_temp" "$THRESHOLD_GPU_TEMP" "gt"; then
            alerts_warning+="GPU${gpu_id}: High GPU temp ${gpu_temp}C exceeds ${THRESHOLD_GPU_TEMP}C\n"
            gpu_temp_violated=true
        fi
        if check_threshold "$mem_temp" "$THRESHOLD_MEM_TEMP" "gt"; then
            alerts_warning+="GPU${gpu_id}: High Memory temp ${mem_temp}C exceeds ${THRESHOLD_MEM_TEMP}C\n"
            gpu_temp_violated=true
        fi
    done <<< "$temp_output"

    # dcgmi로 에러 데이터 수집 (XID, ECC, Row Remap)
    # 240(PVIOL), 241(TVIOL)은 누적값이므로 제외
    local dcgmi_output
    dcgmi_output=$(dcgmi dmon -e 230,312,314,391,392 -c 1 2>/dev/null) || {
        echo "WARNING: dcgmi execution failed, skipping error checks"
        dcgmi_output=""
    }

    if [[ -n "$dcgmi_output" ]]; then
        while IFS= read -r line; do
            [[ -z "$line" || "$line" =~ ^#.* || "$line" =~ ^ID || ! "$line" =~ ^GPU ]] && continue

            read -r gpu_word gpu_id xid dbe_vol dbe_agg ret_dbe remap <<< "$line"

            if check_threshold "$xid" 0 "ne"; then
                alerts_critical+="GPU${gpu_id}: XID Error (value: ${xid})\n"
            fi
            if check_threshold "$dbe_vol" 0 "ne"; then
                alerts_critical+="GPU${gpu_id}: DBE ECC Volatile (count: ${dbe_vol})\n"
            fi
            if check_threshold "$dbe_agg" 0 "ne"; then
                alerts_critical+="GPU${gpu_id}: DBE ECC Aggregate (count: ${dbe_agg})\n"
            fi
            if check_threshold "$remap" 1 "eq"; then
                alerts_critical+="GPU${gpu_id}: Row Remap FAILURE\n"
            fi
            if check_threshold "$ret_dbe" 0 "ne"; then
                alerts_warning+="GPU${gpu_id}: Retired Pages DBE (count: ${ret_dbe})\n"
            fi
        done <<< "$dcgmi_output"
    fi

    # Collect Inlet temperatures via IPMI raw command (fastest method)
    # Sensor IDs: Inlet Temp=0x09, HGX Inlet Temp=0xDA
    local inlet_raw hgx_inlet_raw inlet_temp hgx_inlet_temp
    # local inlet_violated=false

    inlet_raw=$(ipmitool raw 0x04 0x2d 0x09 2>/dev/null | awk '{print $1}') || inlet_raw=""
    hgx_inlet_raw=$(ipmitool raw 0x04 0x2d 0xDA 2>/dev/null | awk '{print $1}') || hgx_inlet_raw=""

    if [[ -n "$inlet_raw" ]]; then
        inlet_temp=$((16#$inlet_raw))
        if check_threshold "$inlet_temp" "$THRESHOLD_INLET_TEMP" "gt"; then
            alerts_warning+="Inlet Temp: ${inlet_temp}C exceeds ${THRESHOLD_INLET_TEMP}C\n"
            # inlet_violated=true
        fi
    fi

    if [[ -n "$hgx_inlet_raw" ]]; then
        hgx_inlet_temp=$((16#$hgx_inlet_raw))
        if check_threshold "$hgx_inlet_temp" "$THRESHOLD_HGX_INLET_TEMP" "gt"; then
            alerts_warning+="HGX Inlet Temp: ${hgx_inlet_temp}C exceeds ${THRESHOLD_HGX_INLET_TEMP}C\n"
            # inlet_violated=true
        fi
    fi

    # [DISABLED] Track consecutive inlet temperature violations
    # local violation_count=0
    # if [[ -f "$INLET_VIOLATION_COUNT_FILE" ]]; then
    #     violation_count=$(cat "$INLET_VIOLATION_COUNT_FILE" 2>/dev/null) || violation_count=0
    # fi
    #
    # if [[ "$inlet_violated" == true ]]; then
    #     violation_count=$((violation_count + 1))
    #     echo "$violation_count" > "$INLET_VIOLATION_COUNT_FILE"
    #     echo "Inlet violation count: $violation_count / $INLET_VIOLATION_THRESHOLD"
    #
    #     if [[ "$violation_count" -ge "$INLET_VIOLATION_THRESHOLD" ]]; then
    #         echo "[ACTION] Inlet temperature exceeded threshold $INLET_VIOLATION_THRESHOLD times consecutively!"
    #         echo "[ACTION] Inlet Temp: ${inlet_temp:-N/A}C, HGX Inlet Temp: ${hgx_inlet_temp:-N/A}C"
    #
    #         # Kill all GPU processes
    #         local gpu_pids
    #         gpu_pids=$(nvidia-smi --query-compute-apps=pid --format=csv,noheader,nounits 2>/dev/null | tr -d ' ' | tr '\n' ' ')
    #         if [[ -n "$gpu_pids" ]]; then
    #             for pid in $gpu_pids; do
    #                 kill -9 "$pid" 2>/dev/null && echo "[ACTION] Killed PID $pid" || echo "[ACTION] Failed to kill PID $pid"
    #             done
    #             send_slack_alert "CRITICAL" "Inlet temp exceeded ${INLET_VIOLATION_THRESHOLD}x consecutively. Killed GPU processes: ${gpu_pids}"
    #         else
    #             echo "[ACTION] No GPU processes found"
    #         fi
    #     fi
    # else
    #     # Reset count when temperature is normal
    #     if [[ "$violation_count" -gt 0 ]]; then
    #         echo "Inlet temperature normal, resetting violation count"
    #         echo "0" > "$INLET_VIOLATION_COUNT_FILE"
    #     fi
    # fi

    # Check for processes using more than 1TB of RAM and kill them
    # 1TB = 1,073,741,824 KB (RSS is in KB)
    local THRESHOLD_RSS_KB=1073741824
    while IFS= read -r line; do
        [[ -z "$line" ]] && continue
        local pid rss_kb comm
        pid=$(echo "$line" | awk '{print $1}')
        rss_kb=$(echo "$line" | awk '{print $2}')
        comm=$(echo "$line" | awk '{print $3}')
        if [[ "$rss_kb" -gt "$THRESHOLD_RSS_KB" ]]; then
            local rss_mb=$(( rss_kb / 1024 ))
            echo "[ACTION] Process ${comm} (PID ${pid}) using ${rss_mb}MB RAM, exceeds 1TB threshold"
            kill -9 "$pid" 2>/dev/null && echo "[ACTION] Killed PID $pid" || echo "[ACTION] Failed to kill PID $pid"
            alerts_critical+="RAM exceeded: Process ${comm} (PID ${pid}) using ${rss_mb}MB, killed\n"
        fi
    done < <(ps -eo pid,rss,comm --no-headers --sort=-rss 2>/dev/null | head -20)

    # Track consecutive GPU temperature violations
    local violation_count=0
    if [[ -f "$GPU_TEMP_VIOLATION_COUNT_FILE" ]]; then
        violation_count=$(cat "$GPU_TEMP_VIOLATION_COUNT_FILE" 2>/dev/null) || violation_count=0
    fi

    if [[ "$gpu_temp_violated" == true ]]; then
        violation_count=$((violation_count + 1))
        echo "$violation_count" > "$GPU_TEMP_VIOLATION_COUNT_FILE"
        echo "GPU temp violation count: $violation_count / $GPU_TEMP_VIOLATION_THRESHOLD"

        if [[ "$violation_count" -ge "$GPU_TEMP_VIOLATION_THRESHOLD" ]]; then
            echo "[ACTION] GPU temperature exceeded threshold $GPU_TEMP_VIOLATION_THRESHOLD times consecutively!"

            # Kill all GPU processes
            local gpu_pids
            gpu_pids=$(nvidia-smi --query-compute-apps=pid --format=csv,noheader,nounits 2>/dev/null | tr -d ' ' | tr '\n' ' ')
            if [[ -n "$gpu_pids" ]]; then
                for pid in $gpu_pids; do
                    kill -9 "$pid" 2>/dev/null && echo "[ACTION] Killed PID $pid" || echo "[ACTION] Failed to kill PID $pid"
                done
                send_slack_alert "CRITICAL" "GPU temp exceeded ${GPU_TEMP_VIOLATION_THRESHOLD}x consecutively. Killed GPU processes: ${gpu_pids}"
            else
                echo "[ACTION] No GPU processes found"
            fi
        fi
    else
        # Reset count when GPU temperature is normal
        if [[ "$violation_count" -gt 0 ]]; then
            echo "GPU temperature normal, resetting violation count"
            echo "0" > "$GPU_TEMP_VIOLATION_COUNT_FILE"
        fi
    fi

    if [[ -n "$alerts_critical" ]]; then
        echo -e "[${TIMESTAMP}] [CRITICAL]\n${alerts_critical}"
        send_slack_alert "CRITICAL" "$(echo -e "$alerts_critical")"
    fi
    if [[ -n "$alerts_warning" ]]; then
        echo -e "[${TIMESTAMP}] [WARNING]\n${alerts_warning}"
        send_slack_alert "WARNING" "$(echo -e "$alerts_warning")"
    fi
    if [[ -z "$alerts_critical" && -z "$alerts_warning" ]]; then
        echo "[${TIMESTAMP}] OK: All GPUs healthy"
    fi
}

main "$@"
