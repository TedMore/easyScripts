#!/bin/bash

# Configuration parameters
LOG_FILE="network_monitor.csv"
ERROR_LOG_FILE="network_monitor_error.csv"
MONITOR_INTERVAL=1
NET_DEV_FILE="/proc/net/dev"
# Log rolling threshold (MB)
LOG_ROLL_SIZE=10

# Check command-line arguments
function check_arguments() {
    if [ $# -eq 0 ]; then
        echo "Please provide the names of network interfaces to be monitored as parameters. Multiple NICs can be specified, separated by spaces."
        exit 1
    fi
}

# Check file permissions
function check_file_permission() {
    if [ ! -r "$NET_DEV_FILE" ]; then
        echo "Unable to read the network device status file $NET_DEV_FILE. Please check the file permissions." >> "$ERROR_LOG_FILE"
        exit 1
    fi
}

# Initialize log files
function init_log_files() {
    echo "$(date "+%Y-%m-%d %H:%M:%S") Network monitoring started..." > "$LOG_FILE"
    > "$ERROR_LOG_FILE"
}

# Generate the header
function generate_header() {
    local header="TIME"
    for NIC in "$@"; do
        header="$header,${NIC}_IN_TPUT,${NIC}_OUT_TPUT,${NIC}_RX_PPS,${NIC}_TX_PPS"
    done
    echo "$header"
}

# Output the header to the console and log file
function print_header() {
    local header=$(generate_header "$@")
    printf "%-20s" "TIME"
    for NIC in "$@"; do
        printf " %-15s %-15s %-15s %-15s" "${NIC}_IN_TPUT" "${NIC}_OUT_TPUT" "${NIC}_RX_PPS" "${NIC}_TX_PPS"
    done
    printf "\n"
    echo "$header" >> "$LOG_FILE"
}

# Function: Convert bytes to appropriate units
function convert_bytes_1000() {
    local bytes=$1
    local bits=$((bytes * 8)) 

    if (( bits == 0 )); then
        echo "0 bps"
        return
    fi
    if (( bits < 1000 )); then
        echo "${bits} bps"
    elif (( bits < 1000 * 1000 )); then
        printf "%.1f Kbps\n" "$(echo "scale=1; $bits / 1000" | bc)"
    elif (( bits < 1000 * 1000 * 1000 )); then
        printf "%.1f Mbps\n" "$(echo "scale=1; $bits / (1000 * 1000)" | bc)"
    else
        printf "%.1f Gbps\n" "$(echo "scale=1; $bits / (1000 * 1000 * 1000)" | bc)"
    fi
}

# Function: Get network interface data
function get_network_data() {
    local nic=$1
    awk -v nic="^$nic:" '$0 ~ nic {print $2, $10, $3, $11}' "$NET_DEV_FILE"
}

# Function: Validate if the data is a valid number
function is_valid_number() {
    if ! [[ $1 =~ ^[0-9]+$ ]]; then
        echo "$(date "+%Y-%m-%d %H:%M:%S") Invalid data read: $1" >> "$ERROR_LOG_FILE"
        return 1
    fi
    return 0
}

# Log rolling function
function roll_logs() {
    local log_size=$(stat -c%s "$LOG_FILE")
    if [ $log_size -ge $((LOG_ROLL_SIZE * 1024 * 1024)) ]; then
        mv "$LOG_FILE" "${LOG_FILE}.$(date +%Y%m%d%H%M%S)"
        init_log_files
        print_header "$@"
    fi
}

# Signal handling function
function cleanup() {
    echo "$(date "+%Y-%m-%d %H:%M:%S") Network monitoring stopped..." >> "$LOG_FILE"
    exit 0
}

# Register signal handling
trap cleanup SIGINT SIGTERM

# Main program
check_arguments "$@"
check_file_permission
init_log_files
print_header "$@"

while true; do
    # 获取当前时间
    TIME_REC=$(date "+%Y-%m-%d %H:%M:%S")

    # Store the old data for each network interface
    declare -A OLD_DATA
    for NIC in "$@"; do
        read OLD_IN OLD_OUT OLD_RX_PACKETS OLD_TX_PACKETS < <(get_network_data "$NIC")
        # Validate the old data
        if ! is_valid_number "$OLD_IN" || ! is_valid_number "$OLD_OUT" || ! is_valid_number "$OLD_RX_PACKETS" || ! is_valid_number "$OLD_TX_PACKETS"; then
            continue
        fi
        OLD_DATA["${NIC}_IN"]=$OLD_IN
        OLD_DATA["${NIC}_OUT"]=$OLD_OUT
        OLD_DATA["${NIC}_RX_PACKETS"]=$OLD_RX_PACKETS
        OLD_DATA["${NIC}_TX_PACKETS"]=$OLD_TX_PACKETS
    done

    # 等待 MONITOR_INTERVAL 时间
    sleep $MONITOR_INTERVAL

    # Store the new data for each network interface
    declare -A NEW_DATA
    retry_count=0
    max_retries=3
    for NIC in "$@"; do
        read NEW_IN NEW_OUT NEW_RX_PACKETS NEW_TX_PACKETS < <(get_network_data "$NIC")
        # Validate the new data
        if ! is_valid_number "$NEW_IN" || ! is_valid_number "$NEW_OUT" || ! is_valid_number "$NEW_RX_PACKETS" || ! is_valid_number "$NEW_TX_PACKETS"; then
            continue
        fi
        while [ "$NEW_IN" -eq "${OLD_DATA["${NIC}_IN"]}" ] && [ "$NEW_OUT" -eq "${OLD_DATA["${NIC}_OUT"]}" ] && [ "$NEW_RX_PACKETS" -eq "${OLD_DATA["${NIC}_RX_PACKETS"]}" ] && [ "$NEW_TX_PACKETS" -eq "${OLD_DATA["${NIC}_TX_PACKETS"]}" ] && [ $retry_count -lt $max_retries ]; do
            sleep 0.1
            read NEW_IN NEW_OUT NEW_RX_PACKETS NEW_TX_PACKETS < <(get_network_data "$NIC")
            if is_valid_number "$NEW_IN" && is_valid_number "$NEW_OUT" && is_valid_number "$NEW_RX_PACKETS" && is_valid_number "$NEW_TX_PACKETS"; then
                retry_count=$((retry_count + 1))
            fi
        done
        if [ $retry_count -eq $max_retries ]; then
            echo "$(date "+%Y-%m-%d %H:%M:%S") No traffic change detected for $NIC after multiple retries." >> "$ERROR_LOG_FILE"
        fi
        NEW_DATA["${NIC}_IN"]=$NEW_IN
        NEW_DATA["${NIC}_OUT"]=$NEW_OUT
        NEW_DATA["${NIC}_RX_PACKETS"]=$NEW_RX_PACKETS
        NEW_DATA["${NIC}_TX_PACKETS"]=$NEW_TX_PACKETS
    done

    # Output the timestamp
    printf "%-20s" "$TIME_REC"

    # Calculate and output the changes in traffic and packet counts for each network interface
    log_line="$TIME_REC"
    for NIC in "$@"; do
        IN_RATE=$(( (NEW_DATA["${NIC}_IN"] - OLD_DATA["${NIC}_IN"]) / $MONITOR_INTERVAL ))
        OUT_RATE=$(( (NEW_DATA["${NIC}_OUT"] - OLD_DATA["${NIC}_OUT"]) / $MONITOR_INTERVAL ))
        IN_TPUT=$(convert_bytes_1000 "$IN_RATE")
        OUT_TPUT=$(convert_bytes_1000 "$OUT_RATE")
        RX_PPS=$(( (NEW_DATA["${NIC}_RX_PACKETS"] - OLD_DATA["${NIC}_RX_PACKETS"]) / $MONITOR_INTERVAL ))
        TX_PPS=$(( (NEW_DATA["${NIC}_TX_PACKETS"] - OLD_DATA["${NIC}_TX_PACKETS"]) / $MONITOR_INTERVAL ))

        printf " %-15s %-15s %-15s %-15s" "$IN_TPUT" "$OUT_TPUT" "$RX_PPS" "$TX_PPS"
        log_line="$log_line,$IN_TPUT,$OUT_TPUT,$RX_PPS,$TX_PPS"
    done
    printf "\n"

    # Record the log
    echo "$log_line" >> "$LOG_FILE"

    # Check for log rolling
    roll_logs "$@"
done
