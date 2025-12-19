# 🚀 Ubuntu Server MTU Optimizer PRO (v2.1)

A high-precision network optimization tool designed to find and apply the perfect **Maximum Transmission Unit (MTU)** for your Ubuntu server. Unlike standard MTU scripts, this version prioritizes **stability, zero packet loss, and low jitter** over theoretical maximums.

## ✨ Key Features
- **Binary Search Discovery:** Quickly identifies the exact Path MTU (PMTUD) for your specific network route.
- **Stability Stress Test:** Runs high-frequency pings (50+ packets) to detect micro-losses and jitter.
- **Intelligent Recommendations:** Automatically suggests a "safety cushion" if your network shows signs of instability.
- **Auto-Apply Logic:** 
    - **Temporary:** Apply and test without risk (resets on reboot).
    - **Permanent:** Automatically writes a custom Netplan configuration (`/etc/netplan/99-mtu-optimizer.yaml`).
- **Ubuntu Native:** Full support for Ubuntu 20.04, 22.04, and 24.04.

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
The script includes a **Safety Verification** step. If you apply a setting that breaks your internet connection, it will automatically attempt to revert to your previous working MTU to prevent you from being locked out of your server.

---
**Maintained by:** [LivingG0D](https://github.com/LivingG0D)
