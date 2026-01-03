# 🚀 Ubuntu Server MTU Optimizer PRO (v2.2)

A high-precision network optimization tool designed to find and apply the perfect **Maximum Transmission Unit (MTU)** for your Ubuntu server. Unlike standard MTU scripts, this version prioritizes **stability, zero packet loss, and low jitter** over theoretical maximums.

## ✨ Key Features
- **Binary Search Discovery:** Quickly identifies the exact Path MTU (PMTUD) for your specific network route.
- **Stability Stress Test:** Runs high-frequency pings (50+ packets) to detect micro-losses and jitter.
- **Intelligent Recommendations:** Automatically suggests a "safety cushion" if your network shows signs of instability.
- **Auto-Apply Logic:**
    - **Temporary:** Apply and test without risk (resets on reboot).
    - **Permanent:** Automatically writes a custom Netplan configuration (`/etc/netplan/99-mtu-optimizer.yaml`).
- **Ubuntu Native:** Full support for Ubuntu 20.04, 22.04, and 24.04.
- **Safe Execution:** Strict error handling, IP validation, and automatic cleanup on interruption.
- **Debug Mode:** Set `VERBOSE=1` for detailed diagnostic output.

## ⚡ Quick Start (One-Line Run)
Run this command to start the optimizer immediately as root:

```bash
curl -sSL https://raw.githubusercontent.com/LivingG0D/mtu_optimizer/main/mtu_optimizer.sh | sudo bash
```

## 🛠️ How it Works
1. **Detection:** Identifies your active network interface and gateway.
2. **Calculation:** Uses a binary search algorithm to find the largest unfragmented packet size.
3. **Stress Testing:** Floods the route with optimized packets to ensure the MTU doesn't cause jitter or drops.
4. **Optimization:** If jitter or loss is detected, it suggests a slightly lower MTU to ensure a smoother data flow.
5. **Application:** Gives you the choice to apply the settings temporarily or permanently via Netplan.

## 📋 Requirements
- Ubuntu Server (20.04+)
- Root/Sudo privileges
- `curl` installed (`sudo apt install curl -y`)

## ⚠️ Safety First
The script includes multiple **Safety Verification** steps:
- **IP Validation:** Prevents malformed or invalid IP addresses from being used.
- **Connection Testing:** Tests MTU changes before making them permanent.
- **Automatic Rollback:** If connection is lost, reverts to your previous working MTU.
- **Cleanup Trap:** If interrupted (Ctrl+C), automatically restores original settings.
- **Netplan Detection:** Checks if Netplan is available before attempting permanent configuration.

## 🔧 Debug Mode
For troubleshooting, run with verbose output:
```bash
curl -sSL https://raw.githubusercontent.com/LivingG0D/mtu_optimizer/main/mtu_optimizer.sh | sudo VERBOSE=1 bash
```

## 📝 Changelog
### v2.2
- Added strict mode (`set -euo pipefail`) for safer execution
- Added IP address validation to prevent invalid input
- Replaced Perl regex with POSIX-compatible parsing (works on all systems)
- Added cleanup trap for Ctrl+C handling
- Improved ping output parsing robustness
- Added Netplan availability check
- Added verbose/debug mode (`VERBOSE=1`)
- Fixed dependency check with correct package names
- All function variables now use `local` to prevent scope pollution

---
**Maintained by:** [LivingG0D](https://github.com/LivingG0D)
