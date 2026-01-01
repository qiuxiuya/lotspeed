#!/bin/bash
#
# LotSpeed v2.0 - BBR v3 + FAST TCP + Hybla Hybrid Edition
# Author: uk0 @ 2025
# GitHub: https://github.com/uk0/lotspeed
#
# Usage:
#   curl -fsSL https://raw.githubusercontent.com/uk0/lotspeed/merge_bl/install.sh | sudo bash
#

set -e

# ================= 配置区域 =================
GITHUB_REPO="uk0/lotspeed"
GITHUB_BRANCH="merge_bl"
INSTALL_DIR="/opt/lotspeed"
MODULE_NAME="lotspeed"
VERSION="2.0"
CONFIG_FILE="/etc/lotspeed.conf"
SYSCTL_FILE="/etc/sysctl.d/99-lotspeed.conf"
CURRENT_TIME=$(date '+%Y-%m-%d %H:%M:%S')
CURRENT_USER=$(whoami)

# ================= 颜色定义 =================
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
MAGENTA='\033[0;35m'
CYAN='\033[0;36m'
WHITE='\033[1;37m'
NC='\033[0m' # No Color

# ================= UI 核心算法 =================
BOX_WIDTH=70

get_width() {
    local str="$1"
    local clean_str=$(echo -e "$str" | sed -r "s/\x1B\[([0-9]{1,2}(;[0-9]{1,2})?)?[mGK]//g")
    local width=0
    local len=${#clean_str}
    for ((i=0; i<len; i++)); do
        local char="${clean_str:$i:1}"
        local ord=$(printf "%d" "'$char" 2>/dev/null || echo 128)
        if [ "$ord" -gt 127 ]; then ((width+=2)); else ((width+=1)); fi
    done
    echo $width
}

repeat_char() {
    local char="$1"
    local count="$2"
    if [ "$count" -gt 0 ]; then
        printf "%0.s$char" $(seq 1 $count)
    fi
}

print_box_top() {
    local color="${1:-$CYAN}"
    echo -ne "${color}╔"
    repeat_char "═" $((BOX_WIDTH - 2))
    echo -e "╗${NC}"
}

print_box_div() {
    local color="${1:-$CYAN}"
    echo -ne "${color}╟"
    repeat_char "─" $((BOX_WIDTH - 2))
    echo -e "╢${NC}"
}

print_box_bottom() {
    local color="${1:-$CYAN}"
    echo -ne "${color}╚"
    repeat_char "═" $((BOX_WIDTH - 2))
    echo -e "╝${NC}"
}

print_box_row() {
    local content="$1"
    local align="${2:-left}"
    local color="${3:-$CYAN}"

    local content_width=$(get_width "$content")
    local total_padding=$((BOX_WIDTH - 2 - content_width))
    if [ $total_padding -lt 0 ]; then total_padding=0; fi

    echo -ne "${color}║${NC}"
    if [ "$align" == "center" ]; then
        local left_pad=$((total_padding / 2))
        local right_pad=$((total_padding - left_pad))
        repeat_char " " $left_pad
        echo -ne "$content"
        repeat_char " " $right_pad
    else
        echo -ne " $content"
        repeat_char " " $((total_padding - 1))
    fi
    echo -e "${color}║${NC}"
}

print_kv_row() {
    local key="$1"
    local val="$2"
    local color="${3:-$CYAN}"

    local key_width=$(get_width "$key")
    local val_width=$(get_width "$val")
    local available=$((BOX_WIDTH - 4))
    local padding=$((available - key_width - val_width))
    [ $padding -lt 1 ] && padding=1

    echo -ne "${color}║${NC} $key"
    repeat_char " " $padding
    echo -e "$val ${color}║${NC}"
}

# ================= 基础日志函数 =================
log_info() { echo -e "${GREEN}[INFO]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }
log_success() { echo -e "${GREEN}[✓]${NC} $1"; }

print_banner() {
    echo -e "${CYAN}"
    cat << "EOF"
╔══════════════════════════════════════════════════════════════════════╗
║                                                                      ║
║      _          _   ____                      _                      ║
║     | |    ___ | |_/ ___| _ __   ___  ___  __| |                     ║
║     | |   / _ \| __\___ \| '_ \ / _ \/ _ \/ _` |                     ║
║     | |__| (_) | |_ ___) | |_) |  __/  __/ (_| |                     ║
║     |_____\___/ \__|____/| .__/ \___|\___|\__,_|                     ║
║                          |_|                                         ║
║                                                                      ║
║            BBR v3 + FAST TCP + Hybla Hybrid Edition                  ║
║                       Version 2.0                                    ║
╚══════════════════════════════════════════════════════════════════════╝
EOF
    echo -e "${NC}"
}

# ================= 安装逻辑函数 =================

check_root() {
    if [[ $EUID -ne 0 ]]; then
        log_error "This script must be run as root"
        echo -e "${YELLOW}Try: curl -fsSL <url> | sudo bash${NC}"
        exit 1
    fi
}

check_system() {
    log_info "Checking system compatibility..."

    if [[ -f /etc/redhat-release ]]; then
        OS="centos"
        OS_VERSION=$(cat /etc/redhat-release | sed 's/.*release \([0-9]\).*/\1/')
    elif [[ -f /etc/debian_version ]]; then
        OS="debian"
        OS_VERSION=$(cat /etc/debian_version | cut -d. -f1)
        if grep -qi ubuntu /etc/os-release 2>/dev/null; then
            OS="ubuntu"
            OS_VERSION=$(grep VERSION_ID /etc/os-release | cut -d'"' -f2 | cut -d. -f1)
        fi
    else
        log_error "Unsupported operating system"
        exit 1
    fi

    KERNEL_VERSION=$(uname -r | cut -d. -f1-2)
    KERNEL_MAJOR=$(echo $KERNEL_VERSION | cut -d. -f1)
    KERNEL_MINOR=$(echo $KERNEL_VERSION | cut -d. -f2)

    # v2.0 需要 kernel 6.x+
    if [[ $KERNEL_MAJOR -lt 6 ]]; then
        log_error "Kernel version must be >= 6.0 (current: $(uname -r))"
        log_info "LotSpeed v2.0 requires Linux Kernel 6.x+ for sysctl interface"
        exit 1
    fi

    ARCH=$(uname -m)
    if [[ "$ARCH" != "x86_64" ]] && [[ "$ARCH" != "aarch64" ]]; then
        log_warn "Architecture $ARCH may not be fully tested"
    fi

    log_success "System: $OS $OS_VERSION (kernel $(uname -r), $ARCH)"
}

install_dependencies() {
    log_info "Installing dependencies..."

    if [[ "$OS" == "centos" ]]; then
        yum install -y gcc make kernel-devel-$(uname -r) kernel-headers-$(uname -r) wget curl bc 2>/dev/null || {
            log_warn "Some packages may be missing, trying alternative..."
            yum install -y gcc make kernel-devel kernel-headers wget curl bc
        }
    elif [[ "$OS" == "debian" ]] || [[ "$OS" == "ubuntu" ]]; then
        apt-get update >/dev/null 2>&1
        apt-get install -y gcc make linux-headers-$(uname -r) wget curl bc 2>/dev/null || {
            log_warn "Some packages may be missing, trying alternative..."
            apt-get install -y gcc make linux-headers-generic wget curl bc
        }
    fi

    log_success "Dependencies installed"
}

download_source() {
    log_info "Downloading LotSpeed v$VERSION source code..."

    mkdir -p $INSTALL_DIR
    cd $INSTALL_DIR

    # 下载 v2.0 源代码
    curl -fsSL "https://raw.githubusercontent.com/$GITHUB_REPO/$GITHUB_BRANCH/lotspeed.c" -o lotspeed.c || {
        log_error "Failed to download lotspeed.c"
        exit 1
    }

    # 创建 Makefile
    cat > Makefile << 'EOF'
obj-m += lotspeed.o

KERNELDIR ?= /lib/modules/$(shell uname -r)/build
PWD := $(shell pwd)

ccflags-y := -std=gnu99 -Wno-declaration-after-statement

all:
	$(MAKE) -C $(KERNELDIR) M=$(PWD) modules

clean:
	$(MAKE) -C $(KERNELDIR) M=$(PWD) clean

install: all
	insmod lotspeed.ko
	@echo "lotspeed" >> /etc/modules-load.d/lotspeed.conf 2>/dev/null || true
	@cp lotspeed.ko /lib/modules/$(shell uname -r)/kernel/net/ipv4/ 2>/dev/null || true
	@depmod -a

uninstall:
	-rmmod lotspeed 2>/dev/null
	@rm -f /etc/modules-load.d/lotspeed.conf
	@rm -f /lib/modules/$(shell uname -r)/kernel/net/ipv4/lotspeed.ko
	@depmod -a
EOF

    log_success "Source code downloaded"
}

compile_module() {
    log_info "Compiling LotSpeed v$VERSION kernel module..."

    cd $INSTALL_DIR
    make clean >/dev/null 2>&1

    if ! make 2>&1; then
        log_error "Compilation failed"
        exit 1
    fi

    if [[ ! -f lotspeed.ko ]]; then
        log_error "Module compilation failed - lotspeed.ko not found"
        exit 1
    fi

    log_success "Module compiled successfully"
}

load_module() {
    log_info "Loading LotSpeed v$VERSION module..."

    rmmod lotspeed 2>/dev/null || true

    insmod $INSTALL_DIR/lotspeed.ko || {
        log_error "Failed to load module"
        dmesg | tail -10
        exit 1
    }

    # 等待 sysctl 接口就绪
    sleep 1

    # 检查 sysctl 接口
    if [[ ! -d /proc/sys/net/ipv4/lotspeed ]]; then
        log_error "sysctl interface not available at /proc/sys/net/ipv4/lotspeed"
        exit 1
    fi

    sysctl -w net.ipv4.tcp_congestion_control=lotspeed >/dev/null 2>&1

    # 持久化设置
    if ! grep -q "net.ipv4.tcp_congestion_control=lotspeed" /etc/sysctl.conf; then
        echo "net.ipv4.tcp_congestion_control=lotspeed" >> /etc/sysctl.conf
    fi

    echo "lotspeed" > /etc/modules-load.d/lotspeed.conf
    cp $INSTALL_DIR/lotspeed.ko /lib/modules/$(uname -r)/kernel/net/ipv4/ 2>/dev/null || true
    depmod -a

    log_success "Module loaded and set as default"
}

# ================= 创建默认配置文件 =================
create_default_config() {
    log_info "Creating default configuration..."

    cat > $CONFIG_FILE << 'EOF'
# LotSpeed v2.0 Configuration File
# BBR v3 + FAST TCP + Hybla Hybrid Edition
#
# This file is loaded at boot and when running 'lotspeed load'
# Edit with: lotspeed edit
# Save current: lotspeed save
# Load config: lotspeed load
#

# ============== 基础参数 ==============
min_cwnd = 4
max_cwnd = 15000
beta = 717

# ============== FAST TCP 延迟控制 ==============
fast_alpha = 20
fast_gamma = 50

# ============== 高延迟优化 (Hybla) ==============
hd_enable = 1
hd_thresh_us = 150000
hd_ref_us = 50000
hd_boost = 25
hd_rho_max = 400
hd_cwnd_gain = 150
hd_pacing_gain = 130
hd_min_cwnd = 10
hd_startup_boost = 50

# ============== 勇敢模式 (抗抖动) ==============
brave_enable = 1
brave_rtt_pct = 25
brave_hold_ms = 300
brave_floor_pct = 85

# ============== 历史缓存 ==============
hist_enable = 1
hist_ttl_sec = 1200
hist_max_entries = 8192

# ============== ECN 支持 ==============
ecn_enable = 1
ecn_factor = 85
ecn_alpha_gain = 16
ecn_alpha_init = 256
ecn_thresh = 50
ecn_max_rtt_us = 5000
full_ecn_cnt = 2
ecn_reprobe_gain = 50

# ============== 启动优化 ==============
turbo_startup = 1
startup_gain = 300
startup_min_rounds = 3

# ============== ACK 聚合 ==============
ack_agg_enable = 1
extra_acked_max_us = 100000

# ============== 恢复优化 ==============
fast_recovery = 1
recovery_boost = 20

# ============== Pacing ==============
pacing_margin = 2
burst_mode = 0

# ============== PROBE_RTT ==============
probe_rtt_cwnd_pct = 50
probe_rtt_duration = 150

# ============== TSO ==============
tso_rtt_shift = 9

# ============== 快速路径 ==============
fast_path = 1

# ============== 丢包检测 ==============
loss_thresh = 2
full_loss_cnt = 6
inflight_headroom = 15

# ============== 带宽探测 ==============
bw_probe_max_rounds = 63
bw_probe_base_us = 2000000
bw_probe_rand_us = 1000000
bw_probe_cwnd_gain = 1
EOF

    chmod 644 $CONFIG_FILE
    log_success "Default config created at $CONFIG_FILE"
}

# ================= 创建管理脚本 =================
create_management_script() {
    log_info "Creating management script..."

    cat > /usr/local/bin/lotspeed << 'SCRIPT_EOF'
#!/bin/bash
# LotSpeed v2.0 Management Script
# sysctl-based parameter management

ACTION=$1
INSTALL_DIR="/opt/lotspeed"
VERSION="2.0"
CONFIG_FILE="/etc/lotspeed.conf"
SYSCTL_FILE="/etc/sysctl.d/99-lotspeed.conf"
SYSCTL_PATH="/proc/sys/net/ipv4/lotspeed"

# 颜色
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
MAGENTA='\033[0;35m'
WHITE='\033[1;37m'
BOLD='\033[1m'
NC='\033[0m'

# ================= UI 算法 =================
BOX_WIDTH=70

get_width() {
    local str="$1"
    local clean_str=$(echo -e "$str" | sed -r "s/\x1B\[([0-9]{1,2}(;[0-9]{1,2})?)?[mGK]//g")
    local width=0
    local len=${#clean_str}
    for ((i=0; i<len; i++)); do
        local char="${clean_str:$i:1}"
        local ord=$(printf "%d" "'$char" 2>/dev/null || echo 128)
        if [ "$ord" -gt 127 ]; then ((width+=2)); else ((width+=1)); fi
    done
    echo $width
}

repeat_char() {
    if [ "$2" -gt 0 ]; then printf "%0.s$1" $(seq 1 $2); fi
}

print_box_top() {
    local color="${1:-$CYAN}"
    echo -ne "${color}╔"
    repeat_char "═" $((BOX_WIDTH - 2))
    echo -e "╗${NC}"
}

print_box_div() {
    local color="${1:-$CYAN}"
    echo -ne "${color}╟"
    repeat_char "─" $((BOX_WIDTH - 2))
    echo -e "╢${NC}"
}

print_box_bottom() {
    local color="${1:-$CYAN}"
    echo -ne "${color}╚"
    repeat_char "═" $((BOX_WIDTH - 2))
    echo -e "╝${NC}"
}

print_box_row() {
    local content="$1"
    local align="${2:-left}"
    local color="${3:-$CYAN}"

    local content_width=$(get_width "$content")
    local total_padding=$((BOX_WIDTH - 2 - content_width))
    [ $total_padding -lt 0 ] && total_padding=0

    echo -ne "${color}║${NC}"
    if [ "$align" == "center" ]; then
        local left_pad=$((total_padding / 2))
        local right_pad=$((total_padding - left_pad))
        repeat_char " " $left_pad
        echo -ne "$content"
        repeat_char " " $right_pad
    else
        echo -ne " $content"
        repeat_char " " $((total_padding - 1))
    fi
    echo -e "${color}║${NC}"
}

print_kv_row() {
    local key="$1"
    local val="$2"
    local color="${3:-$CYAN}"

    local key_width=$(get_width "$key")
    local val_width=$(get_width "$val")
    local available=$((BOX_WIDTH - 4))
    local padding=$((available - key_width - val_width))
    [ $padding -lt 1 ] && padding=1

    echo -ne "${color}║${NC} $key"
    repeat_char " " $padding
    echo -e "$val ${color}║${NC}"
}

# ================= 参数操作 =================

# 读取 sysctl 参数
get_param() {
    local param="$1"
    if [[ -f "$SYSCTL_PATH/$param" ]]; then
        cat "$SYSCTL_PATH/$param" 2>/dev/null
    else
        echo "N/A"
    fi
}

# 设置 sysctl 参数
set_param() {
    local param="$1"
    local value="$2"
    if [[ -f "$SYSCTL_PATH/$param" ]]; then
        echo "$value" > "$SYSCTL_PATH/$param" 2>/dev/null
        return $?
    else
        return 1
    fi
}

# 保存当前配置到文件
save_config() {
    print_box_top "${GREEN}"
    print_box_row "Saving Configuration" "center" "${GREEN}"
    print_box_div "${GREEN}"

    # 创建配置文件
    echo "# LotSpeed v$VERSION Configuration" > $CONFIG_FILE
    echo "# Saved at $(date '+%Y-%m-%d %H:%M:%S')" >> $CONFIG_FILE
    echo "" >> $CONFIG_FILE

    # 同时创建 sysctl.d 配置用于开机自动加载
    echo "# LotSpeed v$VERSION sysctl configuration" > $SYSCTL_FILE
    echo "# Auto-generated at $(date '+%Y-%m-%d %H:%M:%S')" >> $SYSCTL_FILE
    echo "" >> $SYSCTL_FILE

    local count=0
    for param_file in $SYSCTL_PATH/*; do
        if [[ -f "$param_file" ]]; then
            param=$(basename "$param_file")
            value=$(cat "$param_file" 2>/dev/null)
            echo "$param = $value" >> $CONFIG_FILE
            echo "net.ipv4.lotspeed.$param = $value" >> $SYSCTL_FILE
            ((count++))
        fi
    done

    print_kv_row "Config File" "$CONFIG_FILE" "${GREEN}"
    print_kv_row "Sysctl File" "$SYSCTL_FILE" "${GREEN}"
    print_kv_row "Parameters Saved" "$count" "${GREEN}"
    print_box_div "${GREEN}"
    print_box_row "${GREEN}✓ Config will be loaded on boot${NC}" "center" "${GREEN}"
    print_box_bottom "${GREEN}"
}

# 从文件加载配置
load_config() {
    if [[ ! -f "$CONFIG_FILE" ]]; then
        echo -e "${RED}Config file not found: $CONFIG_FILE${NC}"
        return 1
    fi

    print_box_top "${CYAN}"
    print_box_row "Loading Configuration" "center" "${CYAN}"
    print_box_div "${CYAN}"

    local count=0
    local failed=0

    while IFS= read -r line; do
        # 跳过注释和空行
        [[ "$line" =~ ^[[:space:]]*# ]] && continue
        [[ -z "$line" ]] && continue

        # 解析 key = value
        if [[ "$line" =~ ^([a-z_]+)[[:space:]]*=[[:space:]]*(.+)$ ]]; then
            param="${BASH_REMATCH[1]}"
            value="${BASH_REMATCH[2]}"
            # 去除尾部空格
            value=$(echo "$value" | sed 's/[[:space:]]*$//')

            if set_param "$param" "$value"; then
                ((count++))
            else
                ((failed++))
            fi
        fi
    done < "$CONFIG_FILE"

    print_kv_row "Loaded" "${GREEN}$count${NC}" "${CYAN}"
    if [[ $failed -gt 0 ]]; then
        print_kv_row "Failed" "${RED}$failed${NC}" "${CYAN}"
    fi
    print_box_bottom "${CYAN}"
}

# 显示状态
show_status() {
    print_box_top
    print_box_row "LotSpeed v$VERSION Status" "center"
    print_box_row "BBR v3 + FAST TCP + Hybla Hybrid" "center"
    print_box_div

    # 检查模块状态
    if lsmod | grep -q lotspeed; then
        print_kv_row "Module Status" "${GREEN}● Loaded${NC}"
        REF_COUNT=$(lsmod | grep lotspeed | awk '{print $3}')
        print_kv_row "Reference Count" "${CYAN}$REF_COUNT${NC}"
        ACTIVE_CONNS=$(ss -tin 2>/dev/null | grep -c lotspeed || echo "0")
        print_kv_row "Active Connections" "${CYAN}$ACTIVE_CONNS${NC}"
    else
        print_kv_row "Module Status" "${RED}○ Not Loaded${NC}"
        print_box_bottom
        return
    fi

    # 检查当前算法
    CURRENT=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null)
    if [[ "$CURRENT" == "lotspeed" ]]; then
        print_kv_row "Active Algorithm" "${GREEN}lotspeed${NC}"
    else
        print_kv_row "Active Algorithm" "${YELLOW}$CURRENT${NC}"
    fi

    # 检查 sysctl 接口
    if [[ -d "$SYSCTL_PATH" ]]; then
        print_kv_row "Sysctl Interface" "${GREEN}Available${NC}"
    else
        print_kv_row "Sysctl Interface" "${RED}Not Available${NC}"
        print_box_bottom
        return
    fi

    print_box_div
    print_box_row "Current Parameters" "center"
    print_box_div

    # 基础参数
    print_kv_row "min_cwnd" "$(get_param min_cwnd) packets"
    print_kv_row "max_cwnd" "$(get_param max_cwnd) packets"
    print_kv_row "beta" "$(get_param beta) ($(( $(get_param beta) * 100 / 1024 ))%)"

    print_box_div
    print_box_row "FAST TCP" "center"
    print_box_div
    print_kv_row "fast_alpha" "$(get_param fast_alpha) packets"
    print_kv_row "fast_gamma" "$(get_param fast_gamma)%"

    print_box_div
    print_box_row "High Delay (Hybla)" "center"
    print_box_div
    local hd_en=$(get_param hd_enable)
    if [[ "$hd_en" == "1" ]]; then
        print_kv_row "hd_enable" "${GREEN}Enabled${NC}"
    else
        print_kv_row "hd_enable" "Disabled"
    fi
    print_kv_row "hd_thresh_us" "$(get_param hd_thresh_us) us ($(( $(get_param hd_thresh_us) / 1000 ))ms)"
    print_kv_row "hd_cwnd_gain" "$(get_param hd_cwnd_gain)%"

    print_box_div
    print_box_row "ECN Support" "center"
    print_box_div
    local ecn_en=$(get_param ecn_enable)
    if [[ "$ecn_en" == "1" ]]; then
        print_kv_row "ecn_enable" "${GREEN}Enabled${NC}"
    else
        print_kv_row "ecn_enable" "Disabled"
    fi
    print_kv_row "ecn_alpha_gain" "$(get_param ecn_alpha_gain) (1/$(get_param ecn_alpha_gain))"
    print_kv_row "ecn_thresh" "$(get_param ecn_thresh)%"

    print_box_div
    print_box_row "Brave Mode (Anti-Jitter)" "center"
    print_box_div
    local brave_en=$(get_param brave_enable)
    if [[ "$brave_en" == "1" ]]; then
        print_kv_row "brave_enable" "${GREEN}Enabled${NC}"
    else
        print_kv_row "brave_enable" "Disabled"
    fi
    print_kv_row "brave_hold_ms" "$(get_param brave_hold_ms) ms"

    print_box_div
    print_box_row "Fast Path" "center"
    print_box_div
    local fp_en=$(get_param fast_path)
    if [[ "$fp_en" == "1" ]]; then
        print_kv_row "fast_path" "${GREEN}Enabled${NC}"
    else
        print_kv_row "fast_path" "Disabled"
    fi

    print_box_bottom
}

# 显示所有参数
show_all_params() {
    print_box_top
    print_box_row "All Parameters" "center"
    print_box_div

    for param_file in $SYSCTL_PATH/*; do
        if [[ -f "$param_file" ]]; then
            param=$(basename "$param_file")
            value=$(cat "$param_file" 2>/dev/null)
            print_kv_row "$param" "$value"
        fi
    done

    print_box_bottom
}

# 预设配置
apply_preset() {
    PRESET=$1

    print_box_top
    print_box_row "Applying Preset: $PRESET" "center"
    print_box_div

    case $PRESET in
        conservative)
            set_param min_cwnd 4
            set_param max_cwnd 10000
            set_param beta 768
            set_param fast_alpha 15
            set_param fast_gamma 40
            set_param hd_enable 1
            set_param brave_enable 1
            set_param ecn_enable 1
            set_param fast_path 1
            print_box_row "Conservative: Low aggression, high fairness" "left"
            ;;
        balanced)
            set_param min_cwnd 4
            set_param max_cwnd 15000
            set_param beta 717
            set_param fast_alpha 20
            set_param fast_gamma 50
            set_param hd_enable 1
            set_param hd_cwnd_gain 150
            set_param brave_enable 1
            set_param ecn_enable 1
            set_param fast_path 1
            print_box_row "Balanced: Default settings" "left"
            ;;
        aggressive)
            set_param min_cwnd 4
            set_param max_cwnd 20000
            set_param beta 614
            set_param fast_alpha 30
            set_param fast_gamma 60
            set_param hd_enable 1
            set_param hd_cwnd_gain 200
            set_param hd_pacing_gain 150
            set_param brave_enable 1
            set_param brave_floor_pct 90
            set_param ecn_enable 1
            set_param fast_path 1
            print_box_row "Aggressive: High throughput, more queue" "left"
            ;;
        highdelay)
            set_param min_cwnd 10
            set_param max_cwnd 20000
            set_param beta 717
            set_param fast_alpha 30
            set_param fast_gamma 60
            set_param hd_enable 1
            set_param hd_thresh_us 100000
            set_param hd_cwnd_gain 200
            set_param hd_pacing_gain 150
            set_param hd_min_cwnd 20
            set_param hd_startup_boost 80
            set_param brave_enable 1
            set_param brave_hold_ms 500
            set_param ecn_enable 0
            set_param fast_path 1
            print_box_row "High-Delay: Optimized for satellite/intercontinental" "left"
            ;;
        datacenter)
            set_param min_cwnd 4
            set_param max_cwnd 10000
            set_param beta 768
            set_param fast_alpha 10
            set_param fast_gamma 30
            set_param hd_enable 0
            set_param brave_enable 0
            set_param ecn_enable 1
            set_param ecn_factor 90
            set_param ecn_max_rtt_us 10000
            set_param fast_path 1
            print_box_row "Datacenter: Low latency, ECN-focused" "left"
            ;;
        *)
            print_box_row "${RED}Unknown preset: $PRESET${NC}" "left"
            print_box_div
            print_box_row "Available presets:" "left"
            print_kv_row "conservative" "Safe, fair with other flows"
            print_kv_row "balanced" "Default settings"
            print_kv_row "aggressive" "High throughput"
            print_kv_row "highdelay" "Satellite/intercontinental"
            print_kv_row "datacenter" "Low latency, ECN"
            print_box_bottom
            return 1
            ;;
    esac

    print_box_div
    print_box_row "${GREEN}✓ Preset applied. Use 'lotspeed save' to persist.${NC}" "center"
    print_box_bottom
}

# 设置单个参数
set_single_param() {
    PARAM=$1
    VALUE=$2

    if [[ -z "$PARAM" ]] || [[ -z "$VALUE" ]]; then
        print_box_top "${RED}"
        print_box_row "Parameter Set Error" "center" "${RED}"
        print_box_div "${RED}"
        print_box_row "Usage: lotspeed set <parameter> <value>" "left" "${RED}"
        print_box_div "${RED}"
        print_box_row "Examples:" "left" "${RED}"
        print_kv_row "lotspeed set min_cwnd 4" "" "${RED}"
        print_kv_row "lotspeed set fast_alpha 25" "" "${RED}"
        print_kv_row "lotspeed set hd_enable 1" "" "${RED}"
        print_kv_row "lotspeed set ecn_enable 0" "" "${RED}"
        print_box_bottom "${RED}"
        return 1
    fi

    if set_param "$PARAM" "$VALUE"; then
        print_box_top "${GREEN}"
        print_box_row "Parameter Updated" "center" "${GREEN}"
        print_box_div "${GREEN}"
        print_kv_row "$PARAM" "$VALUE" "${GREEN}"
        print_box_div "${GREEN}"
        print_box_row "Use 'lotspeed save' to persist this change" "center" "${GREEN}"
        print_box_bottom "${GREEN}"
    else
        echo -e "${RED}Error: Failed to set $PARAM${NC}"
        echo -e "${YELLOW}Check if parameter exists: ls $SYSCTL_PATH/${NC}"
        return 1
    fi
}

# 编辑配置文件
edit_config() {
    if [[ ! -f "$CONFIG_FILE" ]]; then
        echo -e "${YELLOW}Config file not found, creating default...${NC}"
        save_config
    fi

    EDITOR=${EDITOR:-nano}
    if ! command -v $EDITOR &>/dev/null; then
        EDITOR=vi
    fi

    $EDITOR $CONFIG_FILE

    echo ""
    read -p "Load the edited config now? [Y/n] " -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Nn]$ ]]; then
        load_config
        save_config  # 更新 sysctl.d 文件
    fi
}

get_default_congestion_control() {
    AVAILABLE=$(sysctl net.ipv4.tcp_available_congestion_control | awk -F= '{print $2}')
    if echo "$AVAILABLE" | grep -q "cubic"; then echo "cubic";
    elif echo "$AVAILABLE" | grep -q "reno"; then echo "reno";
    elif echo "$AVAILABLE" | grep -q "bbr"; then echo "bbr";
    else echo "$AVAILABLE" | awk '{print $1}'; fi
}

# ================= 主命令处理 =================
case "$ACTION" in
    start)
        modprobe lotspeed 2>/dev/null || insmod $INSTALL_DIR/lotspeed.ko
        sleep 1
        sysctl -w net.ipv4.tcp_congestion_control=lotspeed >/dev/null
        # 加载保存的配置
        if [[ -f "$CONFIG_FILE" ]]; then
            load_config
        fi
        print_box_top "${GREEN}"
        print_box_row "LotSpeed Started" "center" "${GREEN}"
        print_box_bottom "${GREEN}"
        ;;
    stop)
        DEFAULT_ALGO=$(get_default_congestion_control)
        sysctl -w net.ipv4.tcp_congestion_control=$DEFAULT_ALGO >/dev/null 2>&1
        rmmod lotspeed 2>/dev/null
        print_box_top "${YELLOW}"
        print_box_row "LotSpeed Stopped" "center" "${YELLOW}"
        print_kv_row "Switched to" "$DEFAULT_ALGO" "${YELLOW}"
        print_box_bottom "${YELLOW}"
        ;;
    restart)
        $0 stop
        sleep 1
        $0 start
        ;;
    status)
        show_status
        ;;
    params|all)
        show_all_params
        ;;
    preset)
        apply_preset "$2"
        ;;
    set)
        set_single_param "$2" "$3"
        ;;
    save)
        save_config
        ;;
    load)
        load_config
        ;;
    edit)
        edit_config
        ;;
    log|logs)
        print_box_top
        print_box_row "Kernel Logs (Last 20)" "center"
        print_box_bottom
        dmesg | grep -i lotspeed | tail -20
        ;;
    monitor)
        echo -e "${CYAN}Monitoring logs (Ctrl+C to stop)...${NC}"
        dmesg -w | grep --color=always -i lotspeed
        ;;
    uninstall)
        print_box_top "${MAGENTA}"
        print_box_row "LotSpeed v$VERSION Uninstaller" "center" "${MAGENTA}"
        print_box_div "${MAGENTA}"

        DEFAULT_ALGO=$(get_default_congestion_control)
        print_box_row "Switching to $DEFAULT_ALGO..." "left" "${MAGENTA}"
        sysctl -w net.ipv4.tcp_congestion_control=$DEFAULT_ALGO >/dev/null 2>&1

        if rmmod lotspeed 2>/dev/null; then
            print_kv_row "Module Unload" "${GREEN}Success${NC}" "${MAGENTA}"
        else
            print_kv_row "Module Unload" "${YELLOW}In Use${NC}" "${MAGENTA}"
            print_box_row "${YELLOW}Reboot required for complete removal${NC}" "center" "${MAGENTA}"
        fi

        print_box_row "Removing files..." "left" "${MAGENTA}"
        rm -rf $INSTALL_DIR
        rm -f /etc/modules-load.d/lotspeed.conf
        rm -f /lib/modules/$(uname -r)/kernel/net/ipv4/lotspeed.ko
        rm -f $CONFIG_FILE
        rm -f $SYSCTL_FILE
        depmod -a
        sed -i '/net.ipv4.tcp_congestion_control=lotspeed/d' /etc/sysctl.conf

        print_kv_row "Files Removed" "${GREEN}Done${NC}" "${MAGENTA}"
        print_box_bottom "${MAGENTA}"

        rm -f /usr/local/bin/lotspeed
        ;;
    *)
        print_box_top
        print_box_row "LotSpeed v$VERSION Management" "center"
        print_box_row "BBR v3 + FAST TCP + Hybla Hybrid" "center"
        print_box_div
        print_kv_row "start" "Start LotSpeed"
        print_kv_row "stop" "Stop LotSpeed"
        print_kv_row "restart" "Restart LotSpeed"
        print_kv_row "status" "Show status & key params"
        print_kv_row "params" "Show all parameters"
        print_box_div
        print_kv_row "set <k> <v>" "Set parameter"
        print_kv_row "preset <name>" "Apply preset config"
        print_kv_row "save" "Save current config"
        print_kv_row "load" "Load saved config"
        print_kv_row "edit" "Edit config file"
        print_box_div
        print_kv_row "log" "Show kernel logs"
        print_kv_row "monitor" "Live log monitoring"
        print_kv_row "uninstall" "Remove completely"
        print_box_div
        print_box_row "Presets: conservative, balanced, aggressive," "left"
        print_box_row "         highdelay, datacenter" "left"
        print_box_bottom
        exit 1
        ;;
esac
SCRIPT_EOF

    chmod +x /usr/local/bin/lotspeed
    log_success "Management script created at /usr/local/bin/lotspeed"
}

# ================= 创建 systemd 服务 =================
create_systemd_service() {
    log_info "Creating systemd service for config persistence..."

    cat > /etc/systemd/system/lotspeed.service << 'EOF'
[Unit]
Description=LotSpeed v2.0 Congestion Control
After=network.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/local/bin/lotspeed start
ExecStop=/usr/local/bin/lotspeed stop

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable lotspeed.service >/dev/null 2>&1

    log_success "Systemd service created and enabled"
}

# ================= 结尾显示 =================
show_info() {
    echo ""
    print_box_top "${GREEN}"
    print_box_row "LotSpeed v$VERSION Installation Complete!" "center" "${GREEN}"
    print_box_row "BBR v3 + FAST TCP + Hybla Hybrid Edition" "center" "${GREEN}"
    print_box_bottom "${GREEN}"

    echo ""
    /usr/local/bin/lotspeed status

    echo ""
    print_box_top "${YELLOW}"
    print_box_row "Quick Start Guide" "center" "${YELLOW}"
    print_box_div "${YELLOW}"
    print_kv_row "Show status" "lotspeed status" "${YELLOW}"
    print_kv_row "Show all params" "lotspeed params" "${YELLOW}"
    print_kv_row "Set parameter" "lotspeed set fast_alpha 25" "${YELLOW}"
    print_kv_row "Apply preset" "lotspeed preset balanced" "${YELLOW}"
    print_kv_row "Save config" "lotspeed save" "${YELLOW}"
    print_kv_row "Edit config" "lotspeed edit" "${YELLOW}"
    print_box_div "${YELLOW}"
    print_box_row "Config file: $CONFIG_FILE" "left" "${YELLOW}"
    print_box_row "Sysctl path: /proc/sys/net/ipv4/lotspeed/" "left" "${YELLOW}"
    print_box_bottom "${YELLOW}"
    echo ""
}

error_exit() {
    log_error "$1"
    echo -e "${RED}Installation failed.${NC}"
    exit 1
}

# ================= 主流程 =================
main() {
    clear
    print_banner

    echo -e "${CYAN}Starting installation at $CURRENT_TIME${NC}"
    echo ""

    check_root || error_exit "Root check failed"
    check_system || error_exit "System check failed"
    install_dependencies || error_exit "Dependency installation failed"
    download_source || error_exit "Source download failed"
    compile_module || error_exit "Module compilation failed"
    load_module || error_exit "Module loading failed"
    create_default_config || error_exit "Config creation failed"
    create_management_script || error_exit "Script creation failed"
    create_systemd_service || error_exit "Systemd service creation failed"

    show_info

    echo "[$(date '+%Y-%m-%d %H:%M:%S')] LotSpeed v$VERSION installed by $CURRENT_USER" >> /var/log/lotspeed_install.log
}

main
