#!/bin/bash

# =============================================================================
# Dashboard Library - Source this in run scripts for status reporting
# =============================================================================
# Usage: source ./dashboard_lib.sh
#
# Functions available:
#   dashboard_init <mode> <total_parts>   - Initialize dashboard status
#   dashboard_stage <stage_name>          - Update current stage
#   dashboard_part <part_name>            - Update current part
#   dashboard_step <step_description>     - Update current step
#   dashboard_constraints <count>         - Update constraint count
#   dashboard_complete_part               - Mark a part as completed
#   dashboard_error <message>             - Log an error
#   dashboard_warning <message>           - Log a warning
#   dashboard_finish                      - Mark compilation as complete
#   dashboard_log <message>               - Add message to log
# =============================================================================

DASHBOARD_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DASHBOARD_STATUS_FILE="$DASHBOARD_DIR/.dashboard_status"
DASHBOARD_LOG_FILE="$DASHBOARD_DIR/logs/current.log"
DASHBOARD_ENABLED=${DASHBOARD_ENABLED:-1}

# =============================================================================
# Internal Functions
# =============================================================================

_dashboard_update() {
    local key=$1
    local value=$2

    [ "$DASHBOARD_ENABLED" != "1" ] && return

    if [ -f "$DASHBOARD_STATUS_FILE" ]; then
        if grep -q "^${key}=" "$DASHBOARD_STATUS_FILE" 2>/dev/null; then
            if [[ "$OSTYPE" == "darwin"* ]]; then
                sed -i '' "s/^${key}=.*/${key}=${value}/" "$DASHBOARD_STATUS_FILE" 2>/dev/null
            else
                sed -i "s/^${key}=.*/${key}=${value}/" "$DASHBOARD_STATUS_FILE" 2>/dev/null
            fi
        else
            echo "${key}=${value}" >> "$DASHBOARD_STATUS_FILE"
        fi
    fi
}

_dashboard_read() {
    local key=$1
    if [ -f "$DASHBOARD_STATUS_FILE" ]; then
        grep "^${key}=" "$DASHBOARD_STATUS_FILE" 2>/dev/null | cut -d'=' -f2 || echo ""
    else
        echo ""
    fi
}

# =============================================================================
# Public API Functions
# =============================================================================

# Initialize dashboard status
# Usage: dashboard_init "128-validator" 8
dashboard_init() {
    local mode=${1:-"unknown"}
    local total_parts=${2:-8}

    [ "$DASHBOARD_ENABLED" != "1" ] && return

    mkdir -p "$DASHBOARD_DIR/logs"

    cat > "$DASHBOARD_STATUS_FILE" << EOF
MODE=$mode
STAGE=initializing
PART=
STEP=
START_TIME=$(date +%s)
TOTAL_PARTS=$total_parts
COMPLETED_PARTS=0
CURRENT_CONSTRAINTS=0
PEAK_MEMORY=0
ERRORS=0
WARNINGS=0
LOG_FILE=$DASHBOARD_LOG_FILE
EOF

    # Initialize log file
    echo "=== Compilation started at $(date) ===" > "$DASHBOARD_LOG_FILE"
    echo "Mode: $mode" >> "$DASHBOARD_LOG_FILE"
    echo "Total parts: $total_parts" >> "$DASHBOARD_LOG_FILE"
    echo "==========================================" >> "$DASHBOARD_LOG_FILE"
}

# Update the current stage
# Usage: dashboard_stage "compiling"
dashboard_stage() {
    local stage=$1
    _dashboard_update "STAGE" "$stage"
    dashboard_log "Stage: $stage"
}

# Update the current part being processed
# Usage: dashboard_part "part1a"
dashboard_part() {
    local part=$1
    _dashboard_update "PART" "$part"
    dashboard_log "Processing part: $part"
}

# Update the current step within a stage
# Usage: dashboard_step "Running circom compiler"
dashboard_step() {
    local step=$1
    _dashboard_update "STEP" "$step"
}

# Update the constraint count
# Usage: dashboard_constraints 1234567
dashboard_constraints() {
    local count=$1
    _dashboard_update "CURRENT_CONSTRAINTS" "$count"
}

# Mark a part as completed
# Usage: dashboard_complete_part
dashboard_complete_part() {
    local current=$(_dashboard_read "COMPLETED_PARTS")
    current=${current:-0}
    _dashboard_update "COMPLETED_PARTS" "$((current + 1))"
    dashboard_log "Part completed. Total: $((current + 1))"
}

# Log an error
# Usage: dashboard_error "Compilation failed"
dashboard_error() {
    local message=$1
    local errors=$(_dashboard_read "ERRORS")
    errors=${errors:-0}
    _dashboard_update "ERRORS" "$((errors + 1))"
    dashboard_log "ERROR: $message"
}

# Log a warning
# Usage: dashboard_warning "High memory usage detected"
dashboard_warning() {
    local message=$1
    local warnings=$(_dashboard_read "WARNINGS")
    warnings=${warnings:-0}
    _dashboard_update "WARNINGS" "$((warnings + 1))"
    dashboard_log "WARNING: $message"
}

# Mark compilation as finished
# Usage: dashboard_finish
dashboard_finish() {
    _dashboard_update "STAGE" "complete"
    _dashboard_update "END_TIME" "$(date +%s)"

    local start=$(_dashboard_read "START_TIME")
    local end=$(date +%s)
    local elapsed=$((end - start))
    local hours=$((elapsed / 3600))
    local mins=$(((elapsed % 3600) / 60))
    local secs=$((elapsed % 60))

    dashboard_log "=== Compilation completed at $(date) ==="
    dashboard_log "Total time: ${hours}h ${mins}m ${secs}s"

    # Append to history
    echo "$(date '+%Y-%m-%d %H:%M:%S') | $(_dashboard_read MODE) | ${hours}h ${mins}m ${secs}s | Parts: $(_dashboard_read COMPLETED_PARTS)/$(_dashboard_read TOTAL_PARTS)" >> "$DASHBOARD_DIR/.dashboard_history"
}

# Add a message to the log
# Usage: dashboard_log "Processing..."
dashboard_log() {
    local message=$1
    [ "$DASHBOARD_ENABLED" != "1" ] && return

    if [ -n "$DASHBOARD_LOG_FILE" ]; then
        echo "[$(date '+%H:%M:%S')] $message" >> "$DASHBOARD_LOG_FILE"
    fi
}

# Parse constraint count from circom output
# Usage: echo "$output" | dashboard_parse_constraints
dashboard_parse_constraints() {
    while IFS= read -r line; do
        if [[ "$line" =~ ([0-9]+)[[:space:]]*constraints ]]; then
            dashboard_constraints "${BASH_REMATCH[1]}"
        fi
        echo "$line"
    done
}

# Memory monitoring - call periodically
# Usage: dashboard_check_memory
dashboard_check_memory() {
    [ "$DASHBOARD_ENABLED" != "1" ] && return

    local mem_used
    if [[ "$OSTYPE" == "darwin"* ]]; then
        mem_used=$(vm_stat | awk '
            /Pages active/ {active=$3}
            /Pages wired/ {wired=$4}
            /page size/ {ps=$8}
            END {printf "%.1f", (active+wired)*ps/1024/1024/1024}
        ' | tr -d '.')
    else
        mem_used=$(free -g | awk 'NR==2{print $3}')
    fi

    local peak=$(_dashboard_read "PEAK_MEMORY")
    peak=${peak:-0}

    if (( $(echo "$mem_used > $peak" | bc -l 2>/dev/null || echo 0) )); then
        _dashboard_update "PEAK_MEMORY" "$mem_used"
    fi
}

# =============================================================================
# Exported for subshells
# =============================================================================

export DASHBOARD_STATUS_FILE
export DASHBOARD_LOG_FILE
export DASHBOARD_ENABLED
export -f _dashboard_update _dashboard_read
export -f dashboard_init dashboard_stage dashboard_part dashboard_step
export -f dashboard_constraints dashboard_complete_part
export -f dashboard_error dashboard_warning dashboard_finish dashboard_log
export -f dashboard_parse_constraints dashboard_check_memory
