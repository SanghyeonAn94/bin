#!/bin/bash
#
# 서버 정지 프로토콜 (Graceful Shutdown Protocol)
# 사용법: sudo bash /home/bbungsang/bin/utilities/shutdown_protocol.sh [--dry-run] [--skip-shutdown]
#
# --dry-run       : 실제 kill/stop 하지 않고 대상만 출력
# --skip-shutdown : 프로세스/컨테이너만 정리하고 서버 shutdown은 하지 않음

set -euo pipefail

# ── Slack 설정 ──
if [ -f /etc/gpu_health_monitor.env ]; then
    source /etc/gpu_health_monitor.env
fi
SLACK_WEBHOOK_URL="${SLACK_WEBHOOK_URL:?'SLACK_WEBHOOK_URL is not set. source /etc/gpu_health_monitor.env or export it manually.'}"
HOSTNAME_IP=$(hostname -I | awk '{print $1}')

# ── 색상 ──
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

DRY_RUN=false
SKIP_SHUTDOWN=false
LOG_FILE="/tmp/shutdown_protocol_$(date +%Y%m%d_%H%M%S).log"

for arg in "$@"; do
    case $arg in
        --dry-run) DRY_RUN=true ;;
        --skip-shutdown) SKIP_SHUTDOWN=true ;;
    esac
done

log() {
    local msg="[$(date '+%Y-%m-%d %H:%M:%S')] $1"
    echo -e "$msg" | tee -a "$LOG_FILE"
}

header() {
    echo ""
    log "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    log "${CYAN}  $1${NC}"
    log "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
}

send_slack() {
    local color="$1"
    local title="$2"
    local text="$3"
    local ts
    ts=$(date +%s)
    local timestamp
    timestamp=$(TZ='Asia/Seoul' date '+%Y-%m-%d %H:%M:%S')
    local mode="LIVE"
    [ "$DRY_RUN" = true ] && mode="DRY-RUN"
    local payload="{\"attachments\":[{\"color\":\"${color}\",\"title\":\"[${timestamp}] [${mode}] ${title} - ${HOSTNAME_IP}\",\"text\":\"${text}\",\"ts\":${ts}}]}"
    curl -s -X POST -H 'Content-type: application/json' --data "${payload}" "${SLACK_WEBHOOK_URL}" > /dev/null 2>&1 || true
}

# ── 권한 확인 ──
if [ "$EUID" -ne 0 ] && [ "$DRY_RUN" = false ]; then
    echo -e "${RED}[ERROR] sudo 권한이 필요합니다: sudo bash $0${NC}"
    exit 1
fi

if [ "$DRY_RUN" = true ]; then
    log "${YELLOW}*** DRY-RUN 모드: 실제 동작 없이 대상만 출력합니다 ***${NC}"
fi

send_slack "#ffcc00" "정지 프로토콜 시작" "모드: $([ "$DRY_RUN" = true ] && echo 'DRY-RUN' || echo 'LIVE')"

# ── 활성 사용자 계정 목록 ──
USERS=(bbungsang sean617 dong hjkim kmu9842)

# ====================================================================
# PHASE 1: GPU 프로세스 종료
# ====================================================================
header "PHASE 1: GPU 프로세스 종료"

# 계정별 GPU 프로세스 수 집계
declare -A gpu_user_counts
gpu_pids=()
if command -v nvidia-smi &>/dev/null; then
    while IFS=, read -r pid rest; do
        pid=$(echo "$pid" | xargs)
        [ -z "$pid" ] && continue
        owner=$(ps -o user= -p "$pid" 2>/dev/null || echo "unknown")
        owner=$(echo "$owner" | xargs)
        cmdline=$(ps -o args= -p "$pid" 2>/dev/null || echo "unknown")
        gpu_pids+=("$pid")
        gpu_user_counts[$owner]=$(( ${gpu_user_counts[$owner]:-0} + 1 ))
        log "  ${YELLOW}GPU PID=$pid${NC}  USER=$owner  CMD=$cmdline"
    done < <(nvidia-smi --query-compute-apps=pid --format=csv,noheader,nounits 2>/dev/null)
fi

if [ ${#gpu_pids[@]} -eq 0 ]; then
    log "${GREEN}  GPU 프로세스 없음${NC}"
    send_slack "#36a64f" "PHASE 1: GPU" "GPU 프로세스 없음"
else
    # 계정별 요약 문자열 생성
    gpu_summary=""
    for u in "${!gpu_user_counts[@]}"; do
        gpu_summary+="$u: ${gpu_user_counts[$u]}개, "
    done
    gpu_summary="${gpu_summary%, }"

    log "  총 ${#gpu_pids[@]}개 GPU 프로세스 발견"
    send_slack "#ffcc00" "PHASE 1: GPU 프로세스 ${#gpu_pids[@]}개 발견" "$gpu_summary"

    if [ "$DRY_RUN" = false ]; then
        for pid in "${gpu_pids[@]}"; do
            log "  SIGTERM → PID $pid"
            kill -TERM "$pid" 2>/dev/null || true
        done
        log "  10초 대기 (graceful 종료)..."
        sleep 10
        for pid in "${gpu_pids[@]}"; do
            if kill -0 "$pid" 2>/dev/null; then
                log "  ${RED}SIGKILL → PID $pid (graceful 종료 실패)${NC}"
                kill -9 "$pid" 2>/dev/null || true
            fi
        done
        sleep 2
        remaining=$(nvidia-smi --query-compute-apps=pid --format=csv,noheader,nounits 2>/dev/null | wc -l)
        if [ "$remaining" -eq 0 ]; then
            log "${GREEN}  모든 GPU 프로세스 종료 완료${NC}"
            send_slack "#36a64f" "PHASE 1: 완료" "GPU 프로세스 ${#gpu_pids[@]}개 모두 종료"
        else
            log "${RED}  경고: $remaining 개 GPU 프로세스가 아직 남아있음${NC}"
            send_slack "#ff0000" "PHASE 1: 경고" "${remaining}개 GPU 프로세스 잔존"
        fi
    fi
fi

# ====================================================================
# PHASE 2: 컨테이너 종료 (podman / docker)
# ====================================================================
header "PHASE 2: 컨테이너 종료"

container_summary=""

stop_containers() {
    local runtime=$1
    local user=$2
    local run_cmd

    if [ "$user" = "root" ]; then
        run_cmd="$runtime"
    else
        run_cmd="sudo -u $user $runtime"
    fi

    local containers
    containers=$($run_cmd ps -q 2>/dev/null) || return 0

    if [ -z "$containers" ]; then
        return 0
    fi

    local count
    count=$(echo "$containers" | wc -l)
    log "  ${YELLOW}[$user] $runtime: $count개 실행 중${NC}"
    container_summary+="[$user] $runtime: ${count}개, "

    $run_cmd ps --format "    {{.Names}} ({{.Image}})" 2>/dev/null | while read -r line; do
        log "    $line"
    done

    if [ "$DRY_RUN" = false ]; then
        log "  [$user] $runtime stop --all (timeout 30s)..."
        $run_cmd stop --all -t 30 2>/dev/null || true
        sleep 2
        local remaining
        remaining=$($run_cmd ps -q 2>/dev/null | wc -l)
        if [ "$remaining" -eq 0 ]; then
            log "${GREEN}  [$user] 모든 $runtime 컨테이너 종료 완료${NC}"
        else
            log "${RED}  [$user] $remaining개 컨테이너 아직 실행 중 - force kill${NC}"
            $run_cmd kill $($run_cmd ps -q) 2>/dev/null || true
        fi
    fi
}

for user in "${USERS[@]}"; do
    stop_containers "podman" "$user"
done
stop_containers "podman" "root"

if command -v docker &>/dev/null; then
    docker_containers=$(docker ps -q 2>/dev/null | wc -l)
    if [ "$docker_containers" -gt 0 ]; then
        log "  ${YELLOW}[docker] $docker_containers개 실행 중${NC}"
        container_summary+="[docker]: ${docker_containers}개, "
        docker ps --format "    {{.Names}} ({{.Image}})" 2>/dev/null | while read -r line; do
            log "    $line"
        done
        if [ "$DRY_RUN" = false ]; then
            docker stop $(docker ps -q) 2>/dev/null || true
            log "${GREEN}  Docker 컨테이너 종료 완료${NC}"
        fi
    else
        log "${GREEN}  Docker 컨테이너 없음${NC}"
    fi
fi

container_summary="${container_summary%, }"
if [ -n "$container_summary" ]; then
    send_slack "#ffcc00" "PHASE 2: 컨테이너" "$container_summary"
else
    send_slack "#36a64f" "PHASE 2: 컨테이너" "실행 중인 컨테이너 없음"
fi

# ====================================================================
# PHASE 3: 사용자별 잔여 프로세스 정리
# ====================================================================
header "PHASE 3: 사용자별 잔여 프로세스 정리"

cpu_summary=""

for user in "${USERS[@]}"; do
    pids=$(ps -u "$user" -o pid=,comm= 2>/dev/null | \
        grep -vE '(sshd|bash|zsh|sh|systemd|dbus|ssh-agent|gpg-agent|screen|tmux|claude|node|defunct)' | \
        grep -E '(python|java|go|cargo|rustc|make|gcc|g\+\+|nvcc|torchrun|deepspeed|accelerate)' | \
        awk '{print $1}') || true

    if [ -z "$pids" ]; then
        log "  ${GREEN}[$user] 정리 대상 프로세스 없음${NC}"
        continue
    fi

    count=$(echo "$pids" | wc -w)
    log "  ${YELLOW}[$user] $count개 작업 프로세스 발견:${NC}"
    cpu_summary+="[$user]: ${count}개, "

    for pid in $pids; do
        cmdline=$(ps -o args= -p "$pid" 2>/dev/null | head -c 120 || echo "unknown")
        log "    PID=$pid  $cmdline"
    done

    if [ "$DRY_RUN" = false ]; then
        for pid in $pids; do
            kill -TERM "$pid" 2>/dev/null || true
        done
        sleep 5
        for pid in $pids; do
            if kill -0 "$pid" 2>/dev/null; then
                kill -9 "$pid" 2>/dev/null || true
            fi
        done
        log "${GREEN}  [$user] 프로세스 정리 완료${NC}"
    fi
done

cpu_summary="${cpu_summary%, }"
if [ -n "$cpu_summary" ]; then
    send_slack "#ffcc00" "PHASE 3: CPU 프로세스" "$cpu_summary"
else
    send_slack "#36a64f" "PHASE 3: CPU 프로세스" "정리 대상 프로세스 없음"
fi

# ====================================================================
# PHASE 4: 최종 확인
# ====================================================================
header "PHASE 4: 최종 확인"

log "GPU 상태:"
nvidia_output=$(nvidia-smi 2>/dev/null | head -20) || true
while read -r line; do log "  $line"; done <<< "$nvidia_output"

log ""
log "실행 중인 컨테이너:"
for user in "${USERS[@]}"; do
    cnt=$(sudo -u "$user" podman ps -q 2>/dev/null | wc -l) || cnt=0
    [ "$cnt" -gt 0 ] && log "  ${RED}[$user] podman: $cnt개${NC}" || log "  ${GREEN}[$user] podman: 없음${NC}"
done
docker_cnt=$(docker ps -q 2>/dev/null | wc -l) || docker_cnt=0
[ "$docker_cnt" -gt 0 ] && log "  ${RED}[docker] $docker_cnt개${NC}" || log "  ${GREEN}[docker] 없음${NC}"

log ""
log "로그 저장: $LOG_FILE"
send_slack "#36a64f" "PHASE 4: 최종 확인 완료" "로그: $LOG_FILE"

# ====================================================================
# PHASE 5: 서버 종료
# ====================================================================
if [ "$SKIP_SHUTDOWN" = true ]; then
    log "${YELLOW}--skip-shutdown 옵션으로 서버 종료를 건너뜁니다${NC}"
    exit 0
fi

if [ "$DRY_RUN" = true ]; then
    log "${YELLOW}[DRY-RUN] 여기서 shutdown -h now 가 실행됩니다${NC}"
    send_slack "#36a64f" "정지 프로토콜 완료" "DRY-RUN 종료. 실제 shutdown은 실행되지 않음"
    exit 0
fi

header "PHASE 5: 서버 종료"
send_slack "#ff0000" "PHASE 5: 서버 종료" "5초 후 shutdown -h now 실행"
log "${RED}5초 후 서버가 종료됩니다... (Ctrl+C로 취소)${NC}"
sleep 5
log "shutdown -h now 실행"
shutdown -h now
