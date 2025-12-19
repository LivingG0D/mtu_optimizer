#!/bin/bash

# ==============================================================================
# SCRIPT: Ubuntu Server MTU Optimizer PRO (v2.1)
# DESCRIPTION: 
#   1. Binary Search for Path MTU Discovery (PMTUD).
#   2. High-precision stress testing for packet loss & jitter (stability).
#   3. Logic to prioritize Low Ping/Zero Loss over raw packet size.
#   4. AUTO-APPLY functionality (Temporary & Permanent via Netplan).
#
# COMPATIBILITY: Ubuntu 20.04, 22.04, 24.04
# ==============================================================================

# --- Configuration ---
TARGET="8.8.8.8"           # Reliable Target (Google DNS)
MIN_PAYLOAD=1200           # Floor for search
MAX_PAYLOAD=1472           # Ceiling (1500 MTU - 28 bytes IP/ICMP overhead)
STRESS_COUNT=50            # Packets for stress test (Higher = more accurate)
PING_INTERVAL=0.2          # Fast ping (0.2s) to stress network queues
HEADER_SIZE=28             # 20 bytes IP + 8 bytes ICMP

# --- Colors & Formatting ---
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

# --- Header ---
clear
echo -e "${CYAN}================================================================${NC}"
echo -e "${BOLD}   UBUNTU SERVER MTU OPTIMIZER & STABILITY ANALYZER v2.1    ${NC}"
echo -e "${CYAN}================================================================${NC}"

# --- Root Check ---
if [[ $EUID -ne 0 ]]; then
   echo -e "${RED}[!] Error: This script must be run as root.${NC}"
   exit 1
fi

# --- Dependency Check ---
for cmd in ping awk grep ip; do
    if ! command -v $cmd &> /dev/null; then
        echo -e "${RED}[!] Error: Missing dependency '$cmd'. Installing...${NC}"
        apt-get update && apt-get install -y iputils-ping iproute2
    fi
done

# --- Step 1: Network Detection ---
echo -e "${BLUE}[1/5] Detecting Network Configuration...${NC}"

# Find interface used to reach internet
INTERFACE=$(ip route get $TARGET | sed -n 's/.*dev \([^\ ]*\).*/\1/p')
CURRENT_MTU=$(ip link show "$INTERFACE" | awk '/mtu/ {print $5}')
GATEWAY_IP=$(ip route show default 0.0.0.0/0 | awk '{print $3}')

if [[ -z "$INTERFACE" ]]; then
    echo -e "${RED}[!] Critical: No active internet connection detected.${NC}"
    exit 1
fi

echo -e "      Interface:    ${BOLD}$INTERFACE${NC}"
echo -e "      Current MTU:  ${BOLD}$CURRENT_MTU${NC}"
echo -e "      Gateway:      $GATEWAY_IP"
echo -e "      Target:       $TARGET"
echo ""

# --- Step 2: Binary Search (Path MTU Discovery) ---
echo -e "${BLUE}[2/5] Calculating Max Unfragmented Payload (Binary Search)...${NC}"

low=$MIN_PAYLOAD
high=$MAX_PAYLOAD
best_payload=0

while [ $low -le $high ]; do
    mid=$(( (low + high) / 2 ))
    # -M do = Don't Fragment
    if ping -c 1 -M do -s "$mid" -W 1 "$TARGET" &> /dev/null; then
        best_payload=$mid
        low=$((mid + 1))
    else
        high=$((mid - 1))
    fi
done

if [ "$best_payload" -eq 0 ]; then
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

# Capture output
PING_RES=$(ping -c $STRESS_COUNT -i $PING_INTERVAL -M do -s "$best_payload" "$TARGET")

# Parse Statistics
LOSS_PCT=$(echo "$PING_RES" | grep -oP '\d+(?=% packet loss)')

# Parse Timing (min/avg/max/mdev)
# Output format example: rtt min/avg/max/mdev = 10.1/10.5/12.2/0.4 ms
TIMING=$(echo "$PING_RES" | tail -1 | awk -F '=' '{print $2}' | awk '{print $1}')
R_AVG=$(echo $TIMING | awk -F '/' '{print $2}')
R_MDEV=$(echo $TIMING | awk -F '/' '{print $4}') # This is Jitter

# Handle cases where mdev is missing or 0
if [[ -z "$R_MDEV" ]]; then R_MDEV="0"; fi

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
JITTER_INT=${R_MDEV%.*} 
if [[ -z "$JITTER_INT" ]]; then JITTER_INT=0; fi

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
    echo -e "\n[*] Applying MTU $RECOMMENDED_MTU to $INTERFACE temporarily..."
    ip link set dev "$INTERFACE" mtu "$RECOMMENDED_MTU"
    
    # Safety Verification
    sleep 2
    if ping -c 2 -W 1 "$TARGET" &> /dev/null; then
        echo -e "${GREEN}✔ Success! Connection active. MTU will reset on reboot.${NC}"
    else
        echo -e "${RED}✘ Connection lost! Reverting to $CURRENT_MTU...${NC}"
        ip link set dev "$INTERFACE" mtu "$CURRENT_MTU"
    fi
}

# Function to apply perm (Netplan)
apply_perm() {
    # Test temp first
    echo -e "\n[*] Testing configuration safety first..."
    ip link set dev "$INTERFACE" mtu "$RECOMMENDED_MTU"
    sleep 2
    if ! ping -c 2 -W 1 "$TARGET" &> /dev/null; then
        echo -e "${RED}✘ Test failed. Connection unstable. Aborting permanent change.${NC}"
        ip link set dev "$INTERFACE" mtu "$CURRENT_MTU"
        return
    fi

    NETPLAN_FILE="/etc/netplan/99-mtu-optimizer.yaml"
    echo -e "${GREEN}✔ Connection safe.${NC}"
    echo -e "    Creating Netplan override file: ${CYAN}$NETPLAN_FILE${NC}"
    
    # Create a safe override file
cat <<EOF > "$NETPLAN_FILE"
network:
  version: 2
  ethernets:
    $INTERFACE:
      mtu: $RECOMMENDED_MTU
      dhcp4: true
EOF
    
    chmod 600 "$NETPLAN_FILE"
    echo -e "    Applying Netplan configuration..."
    
    # Try to apply
    if netplan apply; then
        echo -e "${GREEN}✔ Success! MTU $RECOMMENDED_MTU is now permanent.${NC}"
    else
        echo -e "${RED}✘ Error applying netplan. Reverting config file...${NC}"
        rm "$NETPLAN_FILE"
        netplan apply
    fi
}

while true; do
    echo -e "Select an action:"
    echo -e "  [1] Apply ${GREEN}Temporarily${NC} (Lost on reboot - Good for testing)"
    echo -e "  [2] Apply ${RED}Permanently${NC} (Writes to Netplan)"
    echo -e "  [3] Exit (Do nothing)"
    echo ""
    
    # Read from /dev/tty to ensure it works even if piped (e.g., curl ... | bash)
    read -p "Enter choice [1-3]: " choice < /dev/tty
    
    case $choice in
        1)
            apply_temp
            break
            ;;
        2)
            apply_perm
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