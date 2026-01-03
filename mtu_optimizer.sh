#!/bin/bash

# ==============================================================================
# SCRIPT: Ubuntu Server MTU Optimizer PRO (v2.2)
# DESCRIPTION:
#   1. Binary Search for Path MTU Discovery (PMTUD).
#   2. High-precision stress testing for packet loss & jitter (stability).
#   3. Logic to prioritize Low Ping/Zero Loss over raw packet size.
#   4. AUTO-APPLY functionality (Temporary & Permanent via Netplan).
#
# COMPATIBILITY: Ubuntu 20.04, 22.04, 24.04
# ==============================================================================

# --- Strict Mode for Safety ---
set -euo pipefail

# --- Configuration ---
DEFAULT_TARGET="1.1.1.1"      # Default Target (Cloudflare DNS)
MIN_PAYLOAD=1200              # Floor for search
MAX_PAYLOAD=1472              # Ceiling (1500 MTU - 28 bytes IP/ICMP overhead)
STRESS_COUNT=50               # Packets for stress test (Higher = more accurate)
PING_INTERVAL=0.2             # Fast ping (0.2s) to stress network queues
HEADER_SIZE=28                # 20 bytes IP + 8 bytes ICMP
VERBOSE="${VERBOSE:-0}"       # Set VERBOSE=1 for debug output

# --- Global State (for cleanup) ---
ORIGINAL_MTU=""
INTERFACE=""
MTU_CHANGED=0

# --- Colors & Formatting ---
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

# --- Debug Logging ---
log() {
    if [[ "$VERBOSE" -eq 1 ]]; then
        echo -e "${CYAN}[DEBUG]${NC} $*" >&2
    fi
}

# --- Cleanup Trap ---
cleanup() {
    local exit_code=$?
    if [[ "$MTU_CHANGED" -eq 1 && -n "$ORIGINAL_MTU" && -n "$INTERFACE" ]]; then
        echo -e "\n${YELLOW}[*] Cleanup: Restoring original MTU $ORIGINAL_MTU...${NC}" >&2
        ip link set dev "$INTERFACE" mtu "$ORIGINAL_MTU" 2>/dev/null || true
    fi
    exit $exit_code
}

trap cleanup EXIT INT TERM

# --- Target Validation Function ---
validate_target() {
    local target="$1"

    # Check if it's an IP address
    if [[ "$target" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        # Validate each octet is 0-255
        local IFS='.'
        read -ra octets <<< "$target"
        for octet in "${octets[@]}"; do
            if (( octet < 0 || octet > 255 )); then
                return 1
            fi
        done
        return 0
    fi

    # Check if it's a valid hostname/domain
    # Allow alphanumeric, hyphens, and dots (basic DNS name validation)
    if [[ "$target" =~ ^[a-zA-Z0-9]([a-zA-Z0-9.-]*[a-zA-Z0-9])?$ ]]; then
        return 0
    fi

    return 1
}

# --- Header ---
clear
echo -e "${CYAN}================================================================${NC}"
echo -e "${BOLD}   UBUNTU SERVER MTU OPTIMIZER & STABILITY ANALYZER v2.2    ${NC}"
echo -e "${CYAN}================================================================${NC}"

# --- Root Check ---
if [[ $EUID -ne 0 ]]; then
    echo -e "${RED}[!] Error: This script must be run as root.${NC}"
    exit 1
fi

# --- Dependency Check ---
declare -A DEPS=(
    ["ping"]="iputils-ping"
    ["awk"]="gawk"
    ["grep"]="grep"
    ["ip"]="iproute2"
    ["sed"]="sed"
)

for cmd in "${!DEPS[@]}"; do
    if ! command -v "$cmd" &>/dev/null; then
        pkg="${DEPS[$cmd]}"
        echo -e "${YELLOW}[*] Missing dependency '$cmd'. Installing '$pkg'...${NC}"
        if ! timeout 60 apt-get update -qq 2>/dev/null; then
            echo -e "${RED}[!] Warning: apt-get update timed out or failed.${NC}"
        fi
        if ! timeout 120 apt-get install -y -qq "$pkg" 2>/dev/null; then
            echo -e "${RED}[!] Failed to install '$pkg'. Please install manually.${NC}"
            exit 1
        fi
    fi
done

log "All dependencies verified"

# --- Target IP Input ---
echo -e "\n${BLUE}[*] Target IP Configuration${NC}"
echo -e "    Enter the target IP for MTU testing."
echo -e "    Press ${BOLD}Enter${NC} for default: ${CYAN}$DEFAULT_TARGET${NC}"
read -r -p "    Target IP: " USER_TARGET < /dev/tty || USER_TARGET=""

if [[ -z "$USER_TARGET" ]]; then
    TARGET="$DEFAULT_TARGET"
else
    TARGET="$USER_TARGET"
fi

# Validate the target (IP or hostname)
if ! validate_target "$TARGET"; then
    echo -e "${RED}[!] Error: Invalid target format '$TARGET'.${NC}"
    echo -e "${RED}    Expected: IP address (e.g., 1.1.1.1) or hostname (e.g., google.com)${NC}"
    exit 1
fi

echo -e "    Using target: ${GREEN}$TARGET${NC}\n"

# --- Step 1: Network Detection ---
echo -e "${BLUE}[1/5] Detecting Network Configuration...${NC}"

# Find interface used to reach internet
INTERFACE=$(ip route get "$TARGET" 2>/dev/null | sed -n 's/.*dev \([^ ]*\).*/\1/p' | head -1)
log "Detected interface: $INTERFACE"

if [[ -z "$INTERFACE" ]]; then
    echo -e "${RED}[!] Critical: No route to target '$TARGET'. Check connectivity.${NC}"
    exit 1
fi

CURRENT_MTU=$(ip link show "$INTERFACE" 2>/dev/null | awk '/mtu/ {print $5}')
ORIGINAL_MTU="$CURRENT_MTU"  # Store for cleanup
GATEWAY_IP=$(ip route show default 0.0.0.0/0 2>/dev/null | awk '{print $3}' | head -1)

if [[ -z "$CURRENT_MTU" ]]; then
    echo -e "${RED}[!] Critical: Could not determine MTU for interface '$INTERFACE'.${NC}"
    exit 1
fi

echo -e "      Interface:    ${BOLD}$INTERFACE${NC}"
echo -e "      Current MTU:  ${BOLD}$CURRENT_MTU${NC}"
echo -e "      Gateway:      ${GATEWAY_IP:-N/A}"
echo -e "      Target:       $TARGET"
echo ""

# --- Step 2: Binary Search (Path MTU Discovery) ---
echo -e "${BLUE}[2/5] Calculating Max Unfragmented Payload (Binary Search)...${NC}"

low=$MIN_PAYLOAD
high=$MAX_PAYLOAD
best_payload=0

while [[ $low -le $high ]]; do
    mid=$(( (low + high) / 2 ))
    log "Testing payload size: $mid (low=$low, high=$high)"

    # -M do = Don't Fragment
    if ping -c 1 -M do -s "$mid" -W 1 -- "$TARGET" &>/dev/null; then
        best_payload=$mid
        low=$((mid + 1))
    else
        high=$((mid - 1))
    fi
done

if [[ "$best_payload" -eq 0 ]]; then
    echo -e "${RED}[!] Error: All pings failed. Check firewall or connectivity.${NC}"
    exit 1
fi

THEORETICAL_MTU=$((best_payload + HEADER_SIZE))
echo -e "      Max Payload:     ${GREEN}$best_payload bytes${NC}"
echo -e "      Theoretical MTU: ${YELLOW}$THEORETICAL_MTU${NC}"
echo ""

# --- Step 3: Detailed Stress Test ---
echo -e "${BLUE}[3/5] Running Stability Stress Test ($STRESS_COUNT packets)...${NC}"
echo -e "      Testing payload size $best_payload on target $TARGET..."
echo -e "      ${YELLOW}Please wait approx $((STRESS_COUNT / 5)) seconds...${NC}"

# Capture output with error handling
log "Starting stress test: ping -c $STRESS_COUNT -i $PING_INTERVAL -M do -s $best_payload $TARGET"

if ! PING_RES=$(ping -c "$STRESS_COUNT" -i "$PING_INTERVAL" -M do -s "$best_payload" -- "$TARGET" 2>&1); then
    echo -e "${YELLOW}[!] Warning: Stress test had some failures, continuing with partial results...${NC}"
fi

# Parse Statistics (POSIX-compatible, no grep -P)
# Extract packet loss percentage using sed for reliable parsing
LOSS_PCT=$(echo "$PING_RES" | sed -n 's/.*[^0-9]\([0-9]\+\)% packet loss.*/\1/p' | head -1)
if [[ -z "$LOSS_PCT" || ! "$LOSS_PCT" =~ ^[0-9]+$ ]]; then
    LOSS_PCT="100"
fi

log "Parsed packet loss: $LOSS_PCT%"

# Parse Timing (min/avg/max/mdev) - more robust parsing
# Output format example: rtt min/avg/max/mdev = 10.1/10.5/12.2/0.4 ms
STATS_LINE=$(echo "$PING_RES" | grep -E 'rtt|round-trip' || echo "")
R_AVG="N/A"
R_MDEV="0"

if [[ -n "$STATS_LINE" ]]; then
    # Extract the timing values after the = sign
    TIMING=$(echo "$STATS_LINE" | sed -n 's/.*= *\([0-9./]*\).*/\1/p')
    if [[ -n "$TIMING" ]]; then
        R_AVG=$(echo "$TIMING" | awk -F '/' '{print $2}')
        R_MDEV=$(echo "$TIMING" | awk -F '/' '{print $4}')
    fi
fi

# Handle cases where mdev is missing or empty
if [[ -z "$R_MDEV" ]]; then
    R_MDEV="0"
fi
if [[ -z "$R_AVG" ]]; then
    R_AVG="N/A"
fi

log "Parsed timing - Avg: $R_AVG ms, Mdev: $R_MDEV ms"

# --- Step 4: Analysis & Recommendation ---
echo ""
echo -e "${BLUE}[4/5] Detailed Results Analysis${NC}"

# Draw Table
echo -e "${CYAN}----------------------------------------------------------------${NC}"
printf "| %-20s | %-15s | %-20s |\n" "METRIC" "VALUE" "STATUS"
echo -e "${CYAN}----------------------------------------------------------------${NC}"

# 1. Packet Loss Logic
if [[ "$LOSS_PCT" -eq 0 ]]; then
    STATUS_LOSS="${GREEN}PERFECT${NC}"
elif [[ "$LOSS_PCT" -lt 2 ]]; then
    STATUS_LOSS="${YELLOW}ACCEPTABLE${NC}"
else
    STATUS_LOSS="${RED}CRITICAL${NC}"
fi
printf "| %-20s | %-15s | %-20b |\n" "Packet Loss" "$LOSS_PCT%" "$STATUS_LOSS"

# 2. Latency Logic
printf "| %-20s | %-15s | %-20s |\n" "Avg Latency" "${R_AVG} ms" "INFO"

# 3. Jitter Logic (Mdev)
# Strip decimal for integer comparison in bash
JITTER_INT="${R_MDEV%.*}"
if [[ -z "$JITTER_INT" || ! "$JITTER_INT" =~ ^[0-9]+$ ]]; then
    JITTER_INT=0
fi

# Jitter Thresholds: <5ms (Great), <20ms (Ok), >20ms (Bad)
if [[ "$JITTER_INT" -lt 5 ]]; then
    STATUS_JITTER="${GREEN}EXCELLENT${NC}"
elif [[ "$JITTER_INT" -lt 20 ]]; then
    STATUS_JITTER="${YELLOW}OK${NC}"
else
    STATUS_JITTER="${RED}UNSTABLE${NC}"
fi
printf "| %-20s | %-15s | %-20b |\n" "Jitter (Deviation)" "${R_MDEV} ms" "$STATUS_JITTER"
echo -e "${CYAN}----------------------------------------------------------------${NC}"

# --- Recommendation Logic ---
# If any loss or high jitter, suggest dropping MTU by 8-10 bytes for safety cushion
RECOMMENDED_MTU=$THEORETICAL_MTU
REASON="Max efficiency. No issues detected."

if [[ "$LOSS_PCT" -ne 0 ]]; then
    RECOMMENDED_MTU=$((THEORETICAL_MTU - 10))
    REASON="Packet loss detected. Reduced by 10 for stability."
elif [[ "$JITTER_INT" -ge 10 ]]; then
    RECOMMENDED_MTU=$((THEORETICAL_MTU - 8))
    REASON="High Jitter detected. Reduced by 8 for smoother flow."
fi

echo -e "\n${BOLD}OPTIMIZED RECOMMENDATION:${NC}"
echo -e "Optimal MTU:  ${GREEN}$RECOMMENDED_MTU${NC}"
echo -e "Reasoning:    $REASON"
echo ""

# --- Step 5: Auto-Apply ---
echo -e "${BLUE}[5/5] Application Options${NC}"

# Function to apply temp
apply_temp() {
    local new_mtu="$1"
    local iface="$2"
    local target="$3"
    local old_mtu="$4"

    # Validate MTU is a reasonable number
    if [[ ! "$new_mtu" =~ ^[0-9]+$ ]] || (( new_mtu < 68 || new_mtu > 65535 )); then
        echo -e "${RED}[!] Error: Invalid MTU value: $new_mtu (must be 68-65535)${NC}"
        return 1
    fi

    echo -e "\n[*] Applying MTU $new_mtu to $iface temporarily..."
    ip link set dev "$iface" mtu "$new_mtu"
    MTU_CHANGED=1

    # Safety Verification
    sleep 2
    if ping -c 2 -W 1 -- "$target" &>/dev/null; then
        echo -e "${GREEN}✔ Success! Connection active. MTU will reset on reboot.${NC}"
        MTU_CHANGED=0  # Don't revert on exit
    else
        echo -e "${RED}✘ Connection lost! Reverting to $old_mtu...${NC}"
        ip link set dev "$iface" mtu "$old_mtu"
        MTU_CHANGED=0
    fi
}

# Function to apply perm (Netplan)
apply_perm() {
    local new_mtu="$1"
    local iface="$2"
    local target="$3"
    local old_mtu="$4"
    local netplan_file="/etc/netplan/99-mtu-optimizer.yaml"

    # Validate MTU is a reasonable number
    if [[ ! "$new_mtu" =~ ^[0-9]+$ ]] || (( new_mtu < 68 || new_mtu > 65535 )); then
        echo -e "${RED}[!] Error: Invalid MTU value: $new_mtu (must be 68-65535)${NC}"
        return 1
    fi

    # Check if Netplan is available
    if ! command -v netplan &>/dev/null; then
        echo -e "${RED}[!] Error: Netplan not found on this system.${NC}"
        echo -e "${YELLOW}    For non-Netplan systems, use temporary apply or configure manually.${NC}"
        return 1
    fi

    # Test temp first
    echo -e "\n[*] Testing configuration safety first..."
    ip link set dev "$iface" mtu "$new_mtu"
    MTU_CHANGED=1

    sleep 2
    if ! ping -c 2 -W 1 -- "$target" &>/dev/null; then
        echo -e "${RED}✘ Test failed. Connection unstable. Aborting permanent change.${NC}"
        ip link set dev "$iface" mtu "$old_mtu"
        MTU_CHANGED=0
        return 1
    fi

    echo -e "${GREEN}✔ Connection safe.${NC}"
    echo -e "    Creating Netplan override file: ${CYAN}$netplan_file${NC}"

    # Create a safe override file
    cat <<EOF > "$netplan_file"
network:
  version: 2
  ethernets:
    $iface:
      mtu: $new_mtu
      dhcp4: true
EOF

    chmod 600 "$netplan_file"
    echo -e "    Applying Netplan configuration..."

    # Try to apply
    if netplan apply 2>/dev/null; then
        echo -e "${GREEN}✔ Success! MTU $new_mtu is now permanent.${NC}"
        MTU_CHANGED=0
    else
        echo -e "${RED}✘ Error applying netplan. Reverting config file...${NC}"
        rm -f "$netplan_file"
        netplan apply 2>/dev/null || true
        ip link set dev "$iface" mtu "$old_mtu"
        MTU_CHANGED=0
        return 1
    fi
}

while true; do
    echo -e "Select an action:"
    echo -e "  [1] Apply ${GREEN}Temporarily${NC} (Lost on reboot - Good for testing)"
    echo -e "  [2] Apply ${RED}Permanently${NC} (Writes to Netplan)"
    echo -e "  [3] Exit (Do nothing)"
    echo ""

    # Read from /dev/tty to ensure it works even if piped (e.g., curl ... | bash)
    read -r -p "Enter choice [1-3]: " choice < /dev/tty || choice="3"

    case "$choice" in
        1)
            apply_temp "$RECOMMENDED_MTU" "$INTERFACE" "$TARGET" "$CURRENT_MTU"
            break
            ;;
        2)
            apply_perm "$RECOMMENDED_MTU" "$INTERFACE" "$TARGET" "$CURRENT_MTU"
            break
            ;;
        3)
            echo "Exiting without changes."
            break
            ;;
        *)
            echo -e "${RED}[!] Invalid choice '$choice'. Please enter 1, 2, or 3.${NC}\n"
            ;;
    esac
done

echo ""
