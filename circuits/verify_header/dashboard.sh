#!/bin/bash

# =============================================================================
# Circuit Compilation Dashboard
# =============================================================================
# Real-time monitoring dashboard for circuit compilation
# Shows: CPU, Memory, Disk I/O, compilation stages, and progress
#
# Usage:
#   ./dashboard.sh                    # Monitor current/recent compilation
#   ./dashboard.sh --run-128          # Run and monitor 128-validator build
#   ./dashboard.sh --run-128-mini     # Run and monitor 128-mini build
#   ./dashboard.sh --run-mini         # Run and monitor mini (3-part) build
#   ./dashboard.sh --history          # Show compilation history
#   ./dashboard.sh --help             # Show help
#
# The dashboard reads status from .dashboard_status file and displays
# real-time system metrics alongside compilation progress.
# =============================================================================

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
STATUS_FILE="$SCRIPT_DIR/.dashboard_status"
HISTORY_FILE="$SCRIPT_DIR/.dashboard_history"
METRICS_FILE="$SCRIPT_DIR/.dashboard_metrics"
PID_FILE="$SCRIPT_DIR/.dashboard_pid"

# Terminal dimensions
TERM_COLS=$(tput cols 2>/dev/null || echo 80)
TERM_ROWS=$(tput lines 2>/dev/null || echo 24)

# =============================================================================
# Colors and Formatting
# =============================================================================

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
MAGENTA='\033[0;35m'
WHITE='\033[1;37m'
GRAY='\033[0;90m'
NC='\033[0m'

# Bold
BOLD='\033[1m'
DIM='\033[2m'

# Cursor control
SAVE_CURSOR='\033[s'
RESTORE_CURSOR='\033[u'
HIDE_CURSOR='\033[?25l'
SHOW_CURSOR='\033[?25h'
CLEAR_LINE='\033[K'
CLEAR_SCREEN='\033[2J'
HOME='\033[H'

# =============================================================================
# Signal Handling
# =============================================================================

cleanup() {
    echo -e "${SHOW_CURSOR}"
    tput cnorm 2>/dev/null || true
    rm -f "$PID_FILE"
    exit 0
}

trap cleanup EXIT INT TERM

# =============================================================================
# System Metrics Functions
# =============================================================================

get_cpu_usage() {
    if [[ "$OSTYPE" == "darwin"* ]]; then
        # macOS
        top -l 1 -n 0 2>/dev/null | grep "CPU usage" | awk '{print $3}' | tr -d '%' || echo "0"
    else
        # Linux
        grep 'cpu ' /proc/stat | awk '{usage=($2+$4)*100/($2+$4+$5)} END {printf "%.1f", usage}' 2>/dev/null || echo "0"
    fi
}

get_memory_info() {
    if [[ "$OSTYPE" == "darwin"* ]]; then
        # macOS - get memory in GB
        local page_size=$(vm_stat | grep "page size" | awk '{print $8}')
        local pages_free=$(vm_stat | grep "Pages free" | awk '{print $3}' | tr -d '.')
        local pages_active=$(vm_stat | grep "Pages active" | awk '{print $3}' | tr -d '.')
        local pages_inactive=$(vm_stat | grep "Pages inactive" | awk '{print $3}' | tr -d '.')
        local pages_wired=$(vm_stat | grep "Pages wired" | awk '{print $4}' | tr -d '.')
        local pages_compressed=$(vm_stat | grep "Pages occupied by compressor" | awk '{print $5}' | tr -d '.' 2>/dev/null || echo "0")

        local total_mem=$(sysctl -n hw.memsize 2>/dev/null)
        local total_gb=$(echo "scale=1; $total_mem / 1024 / 1024 / 1024" | bc 2>/dev/null || echo "0")

        local used_pages=$((pages_active + pages_wired + pages_compressed))
        local used_bytes=$((used_pages * page_size))
        local used_gb=$(echo "scale=1; $used_bytes / 1024 / 1024 / 1024" | bc 2>/dev/null || echo "0")

        echo "$used_gb $total_gb"
    else
        # Linux
        free -g 2>/dev/null | awk 'NR==2{printf "%.1f %.1f", $3, $2}' || echo "0 0"
    fi
}

get_swap_info() {
    if [[ "$OSTYPE" == "darwin"* ]]; then
        # macOS
        local swap_used=$(sysctl -n vm.swapusage 2>/dev/null | awk '{print $6}' | tr -d 'M' || echo "0")
        local swap_total=$(sysctl -n vm.swapusage 2>/dev/null | awk '{print $3}' | tr -d 'M' || echo "0")
        echo "$swap_used $swap_total"
    else
        # Linux
        free -m 2>/dev/null | awk 'NR==3{print $3, $2}' || echo "0 0"
    fi
}

get_load_average() {
    uptime | awk -F'load average:' '{print $2}' | awk '{print $1}' | tr -d ',' 2>/dev/null || echo "0"
}

get_disk_io() {
    if [[ "$OSTYPE" == "darwin"* ]]; then
        # macOS - simplified
        iostat -d 2>/dev/null | tail -1 | awk '{print $3}' || echo "0"
    else
        # Linux
        iostat -d 1 1 2>/dev/null | tail -2 | head -1 | awk '{print $2}' || echo "0"
    fi
}

# =============================================================================
# Progress Bar Functions
# =============================================================================

draw_progress_bar() {
    local current=$1
    local total=$2
    local width=${3:-40}
    local label=${4:-""}

    if [ "$total" -eq 0 ]; then
        total=1
    fi

    local percent=$((current * 100 / total))
    local filled=$((current * width / total))
    local empty=$((width - filled))

    local bar=""
    for ((i=0; i<filled; i++)); do bar+="█"; done
    for ((i=0; i<empty; i++)); do bar+="░"; done

    if [ -n "$label" ]; then
        printf "%s [%s] %3d%%" "$label" "$bar" "$percent"
    else
        printf "[%s] %3d%%" "$bar" "$percent"
    fi
}

draw_metric_bar() {
    local value=$1
    local max=$2
    local width=${3:-20}
    local color=$4

    local filled=$(echo "scale=0; $value * $width / $max" | bc 2>/dev/null || echo "0")
    [ "$filled" -gt "$width" ] && filled=$width
    local empty=$((width - filled))

    local bar=""
    for ((i=0; i<filled; i++)); do bar+="▓"; done
    for ((i=0; i<empty; i++)); do bar+="░"; done

    echo -e "${color}${bar}${NC}"
}

# =============================================================================
# Status File Functions
# =============================================================================

init_status() {
    local mode=$1
    cat > "$STATUS_FILE" << EOF
MODE=$mode
STAGE=initializing
PART=
STEP=
START_TIME=$(date +%s)
TOTAL_PARTS=8
COMPLETED_PARTS=0
CURRENT_CONSTRAINTS=0
PEAK_MEMORY=0
ERRORS=0
WARNINGS=0
EOF
}

update_status() {
    local key=$1
    local value=$2

    if [ -f "$STATUS_FILE" ]; then
        if grep -q "^${key}=" "$STATUS_FILE"; then
            if [[ "$OSTYPE" == "darwin"* ]]; then
                sed -i '' "s/^${key}=.*/${key}=${value}/" "$STATUS_FILE"
            else
                sed -i "s/^${key}=.*/${key}=${value}/" "$STATUS_FILE"
            fi
        else
            echo "${key}=${value}" >> "$STATUS_FILE"
        fi
    fi
}

read_status() {
    local key=$1
    if [ -f "$STATUS_FILE" ]; then
        grep "^${key}=" "$STATUS_FILE" 2>/dev/null | cut -d'=' -f2 || echo ""
    else
        echo ""
    fi
}

# =============================================================================
# Dashboard Display Functions
# =============================================================================

draw_header() {
    local mode=$(read_status "MODE")
    local stage=$(read_status "STAGE")

    echo -e "${BLUE}╔════════════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${BLUE}║${NC}  ${BOLD}${WHITE}⚡ CIRCUIT COMPILATION DASHBOARD${NC}                                  ${BLUE}║${NC}"
    echo -e "${BLUE}║${NC}  ${GRAY}Mode: ${CYAN}${mode:-N/A}${NC}  ${GRAY}Stage: ${YELLOW}${stage:-idle}${NC}                            ${BLUE}║${NC}"
    echo -e "${BLUE}╚════════════════════════════════════════════════════════════════════╝${NC}"
}

draw_system_metrics() {
    local cpu=$(get_cpu_usage)
    local mem_info=$(get_memory_info)
    local mem_used=$(echo $mem_info | awk '{print $1}')
    local mem_total=$(echo $mem_info | awk '{print $2}')
    local swap_info=$(get_swap_info)
    local swap_used=$(echo $swap_info | awk '{print $1}')
    local swap_total=$(echo $swap_info | awk '{print $2}')
    local load=$(get_load_average)

    # Track peak memory
    local peak_mem=$(read_status "PEAK_MEMORY")
    if [ -n "$mem_used" ] && [ -n "$peak_mem" ]; then
        if (( $(echo "$mem_used > $peak_mem" | bc -l 2>/dev/null || echo 0) )); then
            update_status "PEAK_MEMORY" "$mem_used"
            peak_mem=$mem_used
        fi
    fi

    echo -e ""
    echo -e "${WHITE}${BOLD}┌─ SYSTEM METRICS ────────────────────────────────────────────────────┐${NC}"
    echo -e "${WHITE}│${NC}"

    # CPU
    local cpu_color=$GREEN
    if (( $(echo "$cpu > 80" | bc -l 2>/dev/null || echo 0) )); then cpu_color=$RED
    elif (( $(echo "$cpu > 50" | bc -l 2>/dev/null || echo 0) )); then cpu_color=$YELLOW
    fi
    local cpu_bar=$(draw_metric_bar "${cpu%.*}" 100 25 "$cpu_color")
    printf "${WHITE}│${NC}  ${CYAN}CPU:${NC}    %s ${cpu_color}%5.1f%%${NC}\n" "$cpu_bar" "$cpu"

    # Memory
    local mem_percent=0
    if [ -n "$mem_total" ] && [ "$mem_total" != "0" ]; then
        mem_percent=$(echo "scale=0; $mem_used * 100 / $mem_total" | bc 2>/dev/null || echo 0)
    fi
    local mem_color=$GREEN
    if [ "$mem_percent" -gt 90 ]; then mem_color=$RED
    elif [ "$mem_percent" -gt 70 ]; then mem_color=$YELLOW
    fi
    local mem_bar=$(draw_metric_bar "$mem_percent" 100 25 "$mem_color")
    printf "${WHITE}│${NC}  ${CYAN}Memory:${NC} %s ${mem_color}%5.1f${NC}/${WHITE}%.0f GB${NC}\n" "$mem_bar" "$mem_used" "$mem_total"

    # Swap
    if [ -n "$swap_total" ] && [ "$swap_total" != "0" ] && [ "$swap_total" != "0.00" ]; then
        local swap_percent=$(echo "scale=0; $swap_used * 100 / $swap_total" | bc 2>/dev/null || echo 0)
        local swap_color=$GREEN
        if [ "$swap_percent" -gt 50 ]; then swap_color=$YELLOW; fi
        if [ "$swap_percent" -gt 80 ]; then swap_color=$RED; fi
        local swap_bar=$(draw_metric_bar "$swap_percent" 100 25 "$swap_color")
        printf "${WHITE}│${NC}  ${CYAN}Swap:${NC}   %s ${swap_color}%5.0f${NC}/${WHITE}%.0f MB${NC}\n" "$swap_bar" "$swap_used" "$swap_total"
    fi

    # Load Average
    printf "${WHITE}│${NC}  ${CYAN}Load:${NC}   ${WHITE}%.2f${NC}  ${GRAY}Peak Mem: ${MAGENTA}%.1f GB${NC}\n" "$load" "${peak_mem:-0}"

    echo -e "${WHITE}│${NC}"
    echo -e "${WHITE}└─────────────────────────────────────────────────────────────────────┘${NC}"
}

draw_compilation_progress() {
    local stage=$(read_status "STAGE")
    local part=$(read_status "PART")
    local step=$(read_status "STEP")
    local total_parts=$(read_status "TOTAL_PARTS")
    local completed_parts=$(read_status "COMPLETED_PARTS")
    local start_time=$(read_status "START_TIME")
    local constraints=$(read_status "CURRENT_CONSTRAINTS")

    total_parts=${total_parts:-8}
    completed_parts=${completed_parts:-0}

    echo -e ""
    echo -e "${WHITE}${BOLD}┌─ COMPILATION PROGRESS ──────────────────────────────────────────────┐${NC}"
    echo -e "${WHITE}│${NC}"

    # Overall progress bar
    local progress_bar=$(draw_progress_bar "$completed_parts" "$total_parts" 50 "  Overall")
    echo -e "${WHITE}│${NC}  ${progress_bar}"
    echo -e "${WHITE}│${NC}"

    # Parts status
    echo -e "${WHITE}│${NC}  ${BOLD}Parts Status:${NC}"

    # 8-part layout
    local parts=("1A" "1B" "1C" "1D" "1E" "2" "3A" "3B")
    local part_status=()

    for i in "${!parts[@]}"; do
        if [ "$((i+1))" -lt "$completed_parts" ]; then
            part_status+=("${GREEN}✓${NC}")
        elif [ "$((i+1))" -eq "$completed_parts" ] && [ -n "$part" ]; then
            part_status+=("${YELLOW}●${NC}")
        else
            part_status+=("${GRAY}○${NC}")
        fi
    done

    echo -e "${WHITE}│${NC}  ┌──────┬──────┬──────┬──────┬──────┬──────┬──────┬──────┐"
    echo -e "${WHITE}│${NC}  │ ${part_status[0]} 1A │ ${part_status[1]} 1B │ ${part_status[2]} 1C │ ${part_status[3]} 1D │ ${part_status[4]} 1E │ ${part_status[5]} 2  │ ${part_status[6]} 3A │ ${part_status[7]} 3B │"
    echo -e "${WHITE}│${NC}  └──────┴──────┴──────┴──────┴──────┴──────┴──────┴──────┘"

    echo -e "${WHITE}│${NC}"

    # Current activity
    if [ -n "$stage" ] && [ "$stage" != "idle" ] && [ "$stage" != "complete" ]; then
        echo -e "${WHITE}│${NC}  ${BOLD}Current Activity:${NC}"
        echo -e "${WHITE}│${NC}    Stage: ${CYAN}$stage${NC}"
        [ -n "$part" ] && echo -e "${WHITE}│${NC}    Part:  ${YELLOW}$part${NC}"
        [ -n "$step" ] && echo -e "${WHITE}│${NC}    Step:  ${WHITE}$step${NC}"
        [ -n "$constraints" ] && [ "$constraints" != "0" ] && \
            echo -e "${WHITE}│${NC}    Constraints: ${MAGENTA}$(printf "%'d" "$constraints")${NC}"
    elif [ "$stage" == "complete" ]; then
        echo -e "${WHITE}│${NC}  ${GREEN}${BOLD}✓ COMPILATION COMPLETE${NC}"
    else
        echo -e "${WHITE}│${NC}  ${GRAY}Waiting for compilation to start...${NC}"
    fi

    echo -e "${WHITE}│${NC}"

    # Elapsed time
    if [ -n "$start_time" ] && [ "$start_time" != "0" ]; then
        local now=$(date +%s)
        local elapsed=$((now - start_time))
        local hours=$((elapsed / 3600))
        local mins=$(((elapsed % 3600) / 60))
        local secs=$((elapsed % 60))
        printf "${WHITE}│${NC}  ${BOLD}Elapsed:${NC} %02d:%02d:%02d\n" "$hours" "$mins" "$secs"
    fi

    echo -e "${WHITE}│${NC}"
    echo -e "${WHITE}└─────────────────────────────────────────────────────────────────────┘${NC}"
}

draw_log_tail() {
    local log_file=$(read_status "LOG_FILE")

    echo -e ""
    echo -e "${WHITE}${BOLD}┌─ RECENT LOG OUTPUT ─────────────────────────────────────────────────┐${NC}"

    if [ -n "$log_file" ] && [ -f "$log_file" ]; then
        tail -5 "$log_file" 2>/dev/null | while read -r line; do
            # Truncate long lines
            if [ ${#line} -gt 68 ]; then
                line="${line:0:65}..."
            fi
            echo -e "${WHITE}│${NC}  ${GRAY}$line${NC}"
        done
    else
        echo -e "${WHITE}│${NC}  ${GRAY}No log file available${NC}"
    fi

    echo -e "${WHITE}└─────────────────────────────────────────────────────────────────────┘${NC}"
}

draw_help() {
    echo -e ""
    echo -e "${GRAY}  Press ${WHITE}q${GRAY} to quit | ${WHITE}r${GRAY} to refresh | ${WHITE}h${GRAY} for help${NC}"
}

# =============================================================================
# Main Dashboard Loop
# =============================================================================

run_dashboard() {
    echo -e "${HIDE_CURSOR}"
    tput civis 2>/dev/null || true

    while true; do
        echo -e "${HOME}${CLEAR_SCREEN}"

        draw_header
        draw_system_metrics
        draw_compilation_progress
        draw_log_tail
        draw_help

        # Check for key press (non-blocking)
        read -t 1 -n 1 key 2>/dev/null || true
        case "$key" in
            q|Q) break ;;
            r|R) continue ;;
            h|H)
                echo -e "\n${CYAN}Dashboard Help:${NC}"
                echo -e "  ${WHITE}q${NC} - Quit dashboard"
                echo -e "  ${WHITE}r${NC} - Force refresh"
                echo -e "  ${WHITE}h${NC} - Show this help"
                sleep 2
                ;;
        esac
    done

    echo -e "${SHOW_CURSOR}"
    tput cnorm 2>/dev/null || true
}

# =============================================================================
# Wrapper Functions for Running Builds
# =============================================================================

run_with_monitoring() {
    local script=$1
    local mode=$2

    # Initialize status
    init_status "$mode"

    # Start the build in background
    echo "Starting build: $script"

    # Create a wrapper that updates status
    (
        update_status "STAGE" "starting"
        update_status "LOG_FILE" "$SCRIPT_DIR/logs/current.log"

        # Run the actual build script with output parsing
        "$SCRIPT_DIR/$script" --compile-only 2>&1 | while IFS= read -r line; do
            echo "$line"
            echo "$line" >> "$SCRIPT_DIR/logs/current.log"

            # Parse output to update status
            if [[ "$line" =~ "Compiling Part" ]]; then
                part=$(echo "$line" | grep -oE "Part [^ ]+")
                update_status "STAGE" "compiling"
                update_status "PART" "$part"
                update_status "STEP" "circom compilation"
            elif [[ "$line" =~ "constraints" ]]; then
                constraints=$(echo "$line" | grep -oE "[0-9]+" | head -1)
                update_status "CURRENT_CONSTRAINTS" "$constraints"
            elif [[ "$line" =~ "compiled" ]] || [[ "$line" =~ "Compiled" ]]; then
                completed=$(read_status "COMPLETED_PARTS")
                update_status "COMPLETED_PARTS" "$((completed + 1))"
            elif [[ "$line" =~ "Generating witness" ]]; then
                update_status "STAGE" "witness"
                update_status "STEP" "generating witness"
            elif [[ "$line" =~ "zkey" ]]; then
                update_status "STAGE" "trusted_setup"
                update_status "STEP" "generating zkey"
            elif [[ "$line" =~ "proof" ]]; then
                update_status "STAGE" "proving"
                update_status "STEP" "generating proof"
            elif [[ "$line" =~ "Done" ]] || [[ "$line" =~ "success" ]]; then
                update_status "STAGE" "complete"
            fi
        done

        update_status "STAGE" "complete"
    ) &

    local build_pid=$!
    echo "$build_pid" > "$PID_FILE"

    # Run the dashboard
    run_dashboard

    # Cleanup
    if [ -f "$PID_FILE" ]; then
        kill "$(cat "$PID_FILE")" 2>/dev/null || true
        rm -f "$PID_FILE"
    fi
}

# =============================================================================
# History Functions
# =============================================================================

show_history() {
    echo -e "${BLUE}${BOLD}Compilation History${NC}"
    echo -e "${GRAY}─────────────────────────────────────────────${NC}"

    if [ -f "$HISTORY_FILE" ]; then
        cat "$HISTORY_FILE" | tail -20
    else
        echo -e "${GRAY}No compilation history available${NC}"
    fi
}

# =============================================================================
# Main
# =============================================================================

print_usage() {
    echo -e "${BOLD}Circuit Compilation Dashboard${NC}"
    echo ""
    echo "Usage: $0 [option]"
    echo ""
    echo "Options:"
    echo "  (no args)        Monitor current/recent compilation"
    echo "  --run-128        Run and monitor 128-validator build"
    echo "  --run-128-mini   Run and monitor 128-mini (8 validators) build"
    echo "  --run-mini       Run and monitor mini (3-part) build"
    echo "  --history        Show compilation history"
    echo "  --reset          Reset dashboard status"
    echo "  --help           Show this help"
    echo ""
    echo "Controls (during monitoring):"
    echo "  q - Quit dashboard"
    echo "  r - Force refresh"
    echo "  h - Show help"
}

main() {
    case "${1:-}" in
        --run-128)
            run_with_monitoring "run_128_split.sh" "128-validator"
            ;;
        --run-128-mini)
            run_with_monitoring "run_128_mini.sh" "128-mini"
            ;;
        --run-mini)
            run_with_monitoring "run_mini.sh" "mini-3part"
            ;;
        --history)
            show_history
            ;;
        --reset)
            rm -f "$STATUS_FILE" "$METRICS_FILE"
            echo "Dashboard status reset"
            ;;
        --help|-h)
            print_usage
            ;;
        *)
            # Just run the monitoring dashboard
            if [ ! -f "$STATUS_FILE" ]; then
                init_status "monitoring"
            fi
            run_dashboard
            ;;
    esac
}

main "$@"
