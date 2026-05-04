#!/bin/bash
#
# LotSpeed v3.3 - 一键部署脚本 (完整整合版)
# Author: uk0 @ 2025-11-20 19:14:01
# GitHub: https://github.com/uk0/lotspeed
#
# Usage:
#   curl -fsSL https://raw.githubusercontent.com/uk0/lotspeed/main/install.sh | sudo bash
#   or
#   wget -qO- https://raw.githubusercontent.com/uk0/lotspeed/main/install.sh | sudo bash
#

set -e

# 配置
GITHUB_REPO="qiuxiuya/lotspeed"
GITHUB_BRANCH="main"
INSTALL_DIR="/opt/lotspeed"
MODULE_NAME="lotspeed"
VERSION="3.3"
CURRENT_TIME="2025-11-20 19:14:01"
CURRENT_USER="uk0"
ACTION="${1:-install}"
MAKE_ARGS=()
KERNEL_CONFIG=""
KERNEL_USES_LLVM=0
KERNEL_CLANG_MAJOR=""
LLVM_MAKE_VALUE="1"

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
MAGENTA='\033[0;35m'
CYAN='\033[0;36m'
WHITE='\033[1;37m'
NC='\033[0m' # No Color

# 打印函数
print_banner() {
    echo -e "${CYAN}"
    cat << "EOF"
╔════════════════════════════════════════════════════════════╗
║                                                            ║
║     _          _   ____                      _             ║
║    | |    ___ | |_/ ___| _ __   ___  ___  __| |            ║
║    | |   / _ \| __\___ \| '_ \ / _ \/ _ \/ _` |            ║
║    | |__| (_) | |_ ___) | |_) |  __/  __/ (_| |            ║
║    |_____\___/ \__|____/| .__/ \___|\___|\__,_|            ║
║                         |_|                                ║
║                                                            ║
║                 公路超跑 完整整合版                        ║
║                     Version 3.3                            ║
║                                                            ║
╚════════════════════════════════════════════════════════════╝
EOF
    echo -e "${NC}"
}

log_info() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

log_success() {
    echo -e "${GREEN}[✓]${NC} $1"
}

# 检查 root 权限
check_root() {
    if [[ $EUID -ne 0 ]]; then
        log_error "This script must be run as root"
        echo -e "${YELLOW}Try: curl -fsSL <url> | sudo bash${NC}"
        exit 1
    fi
}

# 检查系统
check_system() {
    log_info "Checking system compatibility..."

    # 检查 OS
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

    # 检查内核版本
    KERNEL_VERSION=$(uname -r | cut -d. -f1-2)
    KERNEL_MAJOR=$(echo $KERNEL_VERSION | cut -d. -f1)
    KERNEL_MINOR=$(echo $KERNEL_VERSION | cut -d. -f2)

    if [[ $KERNEL_MAJOR -lt 4 ]] || ([[ $KERNEL_MAJOR -eq 4 ]] && [[ $KERNEL_MINOR -lt 9 ]]); then
        log_error "Kernel version must be >= 4.9 (current: $(uname -r))"
        exit 1
    fi

    # 检查架构
    ARCH=$(uname -m)
    if [[ "$ARCH" != "x86_64" ]] && [[ "$ARCH" != "aarch64" ]]; then
        log_warn "Architecture $ARCH may not be fully tested"
    fi

    log_success "System: $OS $OS_VERSION (kernel $(uname -r), $ARCH)"
}

detect_kernel_build_toolchain() {
    local kernel_build_dir="/lib/modules/$(uname -r)/build"
    local clang_version_num=""

    KERNEL_CONFIG=""
    KERNEL_USES_LLVM=0
    KERNEL_CLANG_MAJOR=""
    LLVM_MAKE_VALUE="1"
    MAKE_ARGS=()

    if [[ -f "$kernel_build_dir/.config" ]]; then
        KERNEL_CONFIG="$kernel_build_dir/.config"
    elif [[ -f "/boot/config-$(uname -r)" ]]; then
        KERNEL_CONFIG="/boot/config-$(uname -r)"
    fi

    if [[ -n "$KERNEL_CONFIG" ]] && grep -q '^CONFIG_CC_IS_CLANG=y' "$KERNEL_CONFIG"; then
        KERNEL_USES_LLVM=1

        if grep -q '^CONFIG_CLANG_VERSION=' "$KERNEL_CONFIG"; then
            clang_version_num=$(grep '^CONFIG_CLANG_VERSION=' "$KERNEL_CONFIG" | cut -d= -f2)
            if [[ "$clang_version_num" =~ ^[0-9]+$ ]]; then
                KERNEL_CLANG_MAJOR=$((clang_version_num / 10000))
            fi
        fi

        if [[ -z "$KERNEL_CLANG_MAJOR" ]] && [[ -r /proc/version ]]; then
            KERNEL_CLANG_MAJOR=$(sed -n 's/.*clang version \([0-9][0-9]*\)\..*/\1/p' /proc/version | head -n1)
        fi

        if [[ -n "$KERNEL_CLANG_MAJOR" ]]; then
            LLVM_MAKE_VALUE="-$KERNEL_CLANG_MAJOR"
            MAKE_ARGS+=(LLVM="$LLVM_MAKE_VALUE")
            log_info "Detected clang-built kernel from $KERNEL_CONFIG (clang major: $KERNEL_CLANG_MAJOR)"
        else
            MAKE_ARGS+=(LLVM=1)
            log_info "Detected clang-built kernel from $KERNEL_CONFIG (clang version not detected, using generic LLVM=1)"
        fi
    elif [[ -n "$KERNEL_CONFIG" ]]; then
        log_info "Detected gcc-built kernel from $KERNEL_CONFIG"
    else
        log_warn "Kernel config not found, falling back to default gcc toolchain"
    fi
}

# 安装依赖
install_dependencies() {
    log_info "Installing dependencies..."

    if [[ "$OS" == "centos" ]]; then
        if [[ $KERNEL_USES_LLVM -eq 1 ]]; then
            yum install -y gcc make clang llvm lld kernel-devel-$(uname -r) kernel-headers-$(uname -r) wget curl bc 2>/dev/null || {
                log_warn "Some packages may be missing, trying alternative..."
                yum install -y gcc make clang llvm kernel-devel kernel-headers wget curl bc
            }
        else
            yum install -y gcc make kernel-devel-$(uname -r) kernel-headers-$(uname -r) wget curl bc 2>/dev/null || {
                log_warn "Some packages may be missing, trying alternative..."
                yum install -y gcc make kernel-devel kernel-headers wget curl bc
            }
        fi
    elif [[ "$OS" == "debian" ]] || [[ "$OS" == "ubuntu" ]]; then
        apt-get update >/dev/null 2>&1
        if [[ $KERNEL_USES_LLVM -eq 1 ]]; then
            if [[ -n "$KERNEL_CLANG_MAJOR" ]]; then
                apt-get install -y gcc make clang-$KERNEL_CLANG_MAJOR llvm-$KERNEL_CLANG_MAJOR lld-$KERNEL_CLANG_MAJOR linux-headers-$(uname -r) wget curl bc 2>/dev/null || {
                    log_warn "Versioned clang toolchain not found, trying generic clang packages..."
                    apt-get install -y gcc make clang llvm lld linux-headers-$(uname -r) wget curl bc 2>/dev/null || {
                        log_warn "Some packages may be missing, trying alternative..."
                        apt-get install -y gcc make clang llvm lld linux-headers-generic wget curl bc
                    }
                }
            else
                apt-get install -y gcc make clang llvm lld linux-headers-$(uname -r) wget curl bc 2>/dev/null || {
                    log_warn "Some packages may be missing, trying alternative..."
                    apt-get install -y gcc make clang llvm lld linux-headers-generic wget curl bc
                }
            fi
        else
            apt-get install -y gcc make linux-headers-$(uname -r) wget curl bc 2>/dev/null || {
                log_warn "Some packages may be missing, trying alternative..."
                apt-get install -y gcc make linux-headers-generic wget curl bc
            }
        fi
    fi

    log_success "Dependencies installed"
}

uninstall_dependencies() {
    log_info "Removing installed build dependencies..."

    if [[ "$OS" == "centos" ]]; then
        if [[ $KERNEL_USES_LLVM -eq 1 ]]; then
            yum remove -y gcc make clang llvm lld kernel-devel-$(uname -r) kernel-headers-$(uname -r) 2>/dev/null || {
                log_warn "Version-specific packages may be missing, trying generic package names..."
                yum remove -y gcc make clang llvm lld kernel-devel kernel-headers || true
            }
        else
            yum remove -y gcc make kernel-devel-$(uname -r) kernel-headers-$(uname -r) 2>/dev/null || {
                log_warn "Version-specific packages may be missing, trying generic package names..."
                yum remove -y gcc make kernel-devel kernel-headers || true
            }
        fi
    elif [[ "$OS" == "debian" ]] || [[ "$OS" == "ubuntu" ]]; then
        if [[ $KERNEL_USES_LLVM -eq 1 ]]; then
            if [[ -n "$KERNEL_CLANG_MAJOR" ]]; then
                apt-get remove -y gcc make clang-$KERNEL_CLANG_MAJOR llvm-$KERNEL_CLANG_MAJOR lld-$KERNEL_CLANG_MAJOR >/dev/null 2>&1 || {
                    log_warn "Versioned clang packages may be missing, trying generic package names..."
                    apt-get remove -y gcc make clang llvm lld >/dev/null 2>&1 || {
                        log_warn "Package names may differ, trying fallback set..."
                        apt-get remove -y gcc make clang llvm lld linux-headers-generic || true
                    }
                }
            else
                apt-get remove -y gcc make clang llvm lld >/dev/null 2>&1 || {
                    log_warn "Package names may differ, trying fallback set..."
                    apt-get remove -y gcc make clang llvm lld linux-headers-generic || true
                }
            fi
        else
            apt-get remove -y gcc make >/dev/null 2>&1 || {
                log_warn "Package names may differ, trying fallback set..."
                apt-get remove -y gcc make linux-headers-generic || true
            }
        fi
        apt-get autoremove -y >/dev/null 2>&1 || true
    fi

    log_success "Dependencies removed"
}

# 下载源码
download_source() {
    log_info "Downloading LotSpeed v3.3 source code..."

    # 创建安装目录
    mkdir -p $INSTALL_DIR
    cd $INSTALL_DIR

    # 使用我们整合的v3.3版本代码
    # 这里应该下载我们刚才整合的 lotspeed_integrated.c
    # 为了演示，我们创建一个本地文件
    cat > lotspeed.c << 'SOURCE_EOF'
# 这里插入完整的 v3.3 源代码
# 由于代码太长，实际使用时应该从 GitHub 下载
# curl -fsSL "https://raw.githubusercontent.com/$GITHUB_REPO/$GITHUB_BRANCH/lotspeed.c" -o lotspeed.c
SOURCE_EOF

    # 实际应该使用：
    curl -fsSL "https://raw.githubusercontent.com/$GITHUB_REPO/$GITHUB_BRANCH/lotspeed.c" -o lotspeed.c || {
        log_error "Failed to download lotspeed.c"
        exit 1
    }

    # 创建 Makefile
    cat > Makefile << 'EOF'
obj-m += lotspeed.o

KERNELDIR ?= /lib/modules/$(shell uname -r)/build
PWD := $(shell pwd)

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

detect_make_args() {
    if [[ $KERNEL_USES_LLVM -eq 1 ]]; then
        log_info "Enabling make ${MAKE_ARGS[*]}"
    else
        log_info "Using default make parameters"
    fi
}

# 编译模块
compile_module() {
    log_info "Compiling LotSpeed v3.3 kernel module..."

    cd $INSTALL_DIR
    detect_make_args
    make "${MAKE_ARGS[@]}" clean >/dev/null 2>&1

    if ! make "${MAKE_ARGS[@]}" >/dev/null 2>&1; then
        log_error "Compilation failed. Checking error..."
        make "${MAKE_ARGS[@]}" 2>&1 | tail -20
        exit 1
    fi

    if [[ ! -f lotspeed.ko ]]; then
        log_error "Module compilation failed - lotspeed.ko not found"
        exit 1
    fi

    log_success "Module compiled successfully"
}

# 加载模块
load_module() {
    log_info "Loading LotSpeed v3.3 module..."

    # 卸载旧模块（如果存在）
    rmmod lotspeed 2>/dev/null || true

    # 加载新模块
    insmod $INSTALL_DIR/lotspeed.ko || {
        log_error "Failed to load module"
        dmesg | tail -10
        exit 1
    }

    # 设置为默认拥塞控制算法
    sysctl -w net.ipv4.tcp_congestion_control=lotspeed >/dev/null 2>&1

    # 持久化设置
    if ! grep -q "net.ipv4.tcp_congestion_control=lotspeed" /etc/sysctl.conf; then
        echo "net.ipv4.tcp_congestion_control=lotspeed" >> /etc/sysctl.conf
    fi

    # 设置开机自动加载
    echo "lotspeed" > /etc/modules-load.d/lotspeed.conf
    cp $INSTALL_DIR/lotspeed.ko /lib/modules/$(uname -r)/kernel/net/ipv4/ 2>/dev/null || true
    depmod -a

    log_success "Module loaded and set as default"
}

# 创建管理脚本
create_management_script() {
    log_info "Creating management script..."

    cat > /usr/local/bin/lotspeed << 'SCRIPT_EOF'
#!/bin/bash
# LotSpeed v3.3 Management Script
# Generated by installer at 2025-11-20 19:14:01
# Author: uk0

ACTION=$1
INSTALL_DIR="/opt/lotspeed"
VERSION="3.3"
CURRENT_TIME="2025-11-20 19:14:01"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
MAGENTA='\033[0;35m'
WHITE='\033[1;37m'
NC='\033[0m'

# 获取系统默认的拥塞控制算法（通常是 cubic）
get_default_congestion_control() {
    # 检查可用的算法
    AVAILABLE=$(sysctl net.ipv4.tcp_available_congestion_control | awk -F= '{print $2}')

    # 优先使用 cubic，其次是 reno
    if echo "$AVAILABLE" | grep -q "cubic"; then
        echo "cubic"
    elif echo "$AVAILABLE" | grep -q "reno"; then
        echo "reno"
    elif echo "$AVAILABLE" | grep -q "bbr"; then
        echo "bbr"
    else
        # 返回第一个可用的算法
        echo "$AVAILABLE" | awk '{print $1}'
    fi
}

# 获取状态名称
get_state_name() {
    case $1 in
        0) echo "STARTUP" ;;
        1) echo "PROBING" ;;
        2) echo "CRUISING" ;;
        3) echo "AVOIDING" ;;
        4) echo "PROBE_RTT" ;;
        *) echo "UNKNOWN" ;;
    esac
}

# 安全停止函数
safe_stop() {
    echo -e "${YELLOW}Preparing to stop LotSpeed v$VERSION...${NC}"

    # 获取默认算法
    DEFAULT_ALGO=$(get_default_congestion_control)

    # 1. 切换到默认算法
    echo -e "${CYAN}Step 1: Switching to default algorithm: $DEFAULT_ALGO${NC}"
    sysctl -w net.ipv4.tcp_congestion_control=$DEFAULT_ALGO >/dev/null 2>&1

    # 设置强制卸载标志（如果参数存在）
    if [ -f /sys/module/lotspeed/parameters/force_unload ]; then
        echo 1 > /sys/module/lotspeed/parameters/force_unload 2>/dev/null || true
    fi

    # 2. 检查活动连接
    echo -e "${CYAN}Step 2: Checking active connections${NC}"
    ACTIVE_CONNS=$(ss -tin 2>/dev/null | grep -c lotspeed 2>/dev/null || echo "0")
    if [ "$ACTIVE_CONNS" -gt 0 ]; then
        echo -e "${YELLOW}Warning: Found $ACTIVE_CONNS active connections using lotspeed${NC}"
        echo -e "${YELLOW}Waiting for connections to close (max 10 seconds)...${NC}"

        # 等待最多10秒
        for i in {1..10}; do
            sleep 1
            ACTIVE_CONNS=$(ss -tin 2>/dev/null | grep -c lotspeed 2>/dev/null || echo "0")
            if [ "$ACTIVE_CONNS" -eq 0 ]; then
                echo -e "${GREEN}All connections closed${NC}"
                break
            fi
            echo -n "."
        done
        echo

        if [ "$ACTIVE_CONNS" -gt 0 ]; then
            echo -e "${YELLOW}Still have $ACTIVE_CONNS connections${NC}"
            echo -e "${YELLOW}Module may not unload until connections close${NC}"
        fi
    fi

    # 3. 检查模块引用计数
    echo -e "${CYAN}Step 3: Checking module reference count${NC}"
    if lsmod | grep -q lotspeed; then
        REF_COUNT=$(lsmod | grep lotspeed | awk '{print $3}')
        if [ ! -z "$REF_COUNT" ] && [ "$REF_COUNT" -gt 0 ]; then
            echo -e "${YELLOW}Module reference count: $REF_COUNT${NC}"
        fi
    fi

    # 4. 尝试卸载模块
    echo -e "${CYAN}Step 4: Attempting to unload module${NC}"
    if rmmod lotspeed 2>/dev/null; then
        echo -e "${GREEN}✓ LotSpeed module unloaded successfully${NC}"
        echo -e "${GREEN}✓ TCP congestion control switched to: $DEFAULT_ALGO${NC}"
        return 0
    else
        echo -e "${YELLOW}⚠ Module is still in use and cannot be unloaded${NC}"
        echo -e "${GREEN}✓ LotSpeed is STOPPED (algorithm switched to $DEFAULT_ALGO)${NC}"
        echo -e "${CYAN}  Module will be unloaded when all connections close${NC}"
        return 0
    fi
}

# 安全卸载函数
safe_uninstall() {
    echo -e "${YELLOW}╔════════════════════════════════════════════════════════╗${NC}"
    echo -e "${YELLOW}║           Uninstalling LotSpeed v$VERSION                   ║${NC}"
    echo -e "${YELLOW}╚════════════════════════════════════════════════════════╝${NC}"
    echo ""

    # 1. 尝试停止模块
    echo -e "${CYAN}Phase 1: Stopping LotSpeed service${NC}"
    safe_stop
    echo ""

    # 2. 删除文件
    echo -e "${CYAN}Phase 2: Removing installation files${NC}"
    echo "  • Removing $INSTALL_DIR"
    rm -rf $INSTALL_DIR
    echo "  • Removing /etc/modules-load.d/lotspeed.conf"
    rm -f /etc/modules-load.d/lotspeed.conf
    echo "  • Removing /lib/modules/$(uname -r)/kernel/net/ipv4/lotspeed.ko"
    rm -f /lib/modules/$(uname -r)/kernel/net/ipv4/lotspeed.ko
    echo "  • Updating module dependencies"
    depmod -a
    echo ""

    # 3. 清理配置
    echo -e "${CYAN}Phase 3: Cleaning system configuration${NC}"
    echo "  • Removing lotspeed from /etc/sysctl.conf"
    sed -i '/net.ipv4.tcp_congestion_control=lotspeed/d' /etc/sysctl.conf

    # 获取当前算法
    CURRENT_ALGO=$(sysctl -n net.ipv4.tcp_congestion_control)
    echo "  • Current TCP algorithm: $CURRENT_ALGO"
    echo ""

    # 4. 检查模块状态
    echo -e "${CYAN}Phase 4: Final status check${NC}"
    if lsmod | grep -q lotspeed; then
        REF_COUNT=$(lsmod | grep lotspeed | awk '{print $3}')
        echo -e "${YELLOW}⚠ Module is still loaded with $REF_COUNT references${NC}"
        echo -e "${MAGENTA}╔════════════════════════════════════════════════════════╗${NC}"
        echo -e "${MAGENTA}║                    IMPORTANT NOTICE                    ║${NC}"
        echo -e "${MAGENTA}╟────────────────────────────────────────────────────────╢${NC}"
        echo -e "${MAGENTA}║  The LotSpeed kernel module cannot be unloaded now     ║${NC}"
        echo -e "${MAGENTA}║  because there are still active connections using it.  ║${NC}"
        echo -e "${MAGENTA}║                                                        ║${NC}"
        echo -e "${MAGENTA}║  ${WHITE}➤ REBOOT YOUR SYSTEM to completely remove the module ${MAGENTA} ║${NC}"
        echo -e "${MAGENTA}║                                                        ║${NC}"
        echo -e "${MAGENTA}║  After reboot, the module will NOT be loaded           ║${NC}"
        echo -e "${MAGENTA}║  automatically as we have removed all startup configs. ║${NC}"
        echo -e "${MAGENTA}╚════════════════════════════════════════════════════════╝${NC}"
        echo ""
        echo -e "${YELLOW}Active connections still using LotSpeed:${NC}"
        ss -tin 2>/dev/null | grep lotspeed | head -5 || echo "  Unable to list connections"
    else
        echo -e "${GREEN}✓ LotSpeed module has been completely removed${NC}"
    fi
    echo ""

    # 5. 删除管理脚本（最后删除自己）
    echo -e "${GREEN}═══════════════════════════════════════════════════════${NC}"
    echo -e "${GREEN}        LotSpeed v$VERSION has been uninstalled${NC}"
    echo -e "${GREEN}═══════════════════════════════════════════════════════${NC}"
    echo -e "${CYAN}• Files removed: ✓${NC}"
    echo -e "${CYAN}• Configuration cleaned: ✓${NC}"
    echo -e "${CYAN}• TCP algorithm: $CURRENT_ALGO${NC}"

    if lsmod | grep -q lotspeed; then
        echo -e "${YELLOW}• Kernel module: Will be removed after reboot${NC}"
        echo ""
        echo -e "${RED}👉 Please REBOOT your system to complete the uninstallation${NC}"
    else
        echo -e "${GREEN}• Kernel module: Removed ✓${NC}"
        echo ""
        echo -e "${GREEN}Uninstallation completed successfully!${NC}"
    fi

    # 删除自己
    rm -f /usr/local/bin/lotspeed
}

show_status() {
    echo -e "${CYAN}═══════════════════════════════════════════════════════${NC}"
    echo -e "${CYAN}         LotSpeed v$VERSION Status Report${NC}"
    echo -e "${CYAN}═══════════════════════════════════════════════════════${NC}"

    # 检查模块是否加载
    if lsmod | grep -q lotspeed; then
        echo -e "Module Status: ${GREEN}Loaded ✓${NC}"

        # 显示引用计数
        REF_COUNT=$(lsmod | grep lotspeed | awk '{print $3}')
        echo -e "Reference Count: ${CYAN}$REF_COUNT${NC}"

        # 显示活动连接数
        ACTIVE_CONNS=$(ss -tin 2>/dev/null | grep -c lotspeed 2>/dev/null || echo "0")
        echo -e "Active Connections: ${CYAN}$ACTIVE_CONNS${NC}"
    else
        echo -e "Module Status: ${RED}Not Loaded ✗${NC}"
        return
    fi

    # 检查是否为当前算法
    CURRENT=$(sysctl -n net.ipv4.tcp_congestion_control)
    if [[ "$CURRENT" == "lotspeed" ]]; then
        echo -e "Active Algorithm: ${GREEN}lotspeed ✓${NC}"
    else
        echo -e "Active Algorithm: ${YELLOW}$CURRENT${NC}"
    fi

    echo ""
    echo -e "${CYAN}Current Parameters:${NC}"
    echo "───────────────────────────────────────────────────────"

    if [[ -d /sys/module/lotspeed/parameters ]]; then
        for param in /sys/module/lotspeed/parameters/*; do
            name=$(basename $param)
            value=$(cat $param 2>/dev/null)
            case $name in
                lotserver_rate)
                    gbps=$((value / 125000000))
                    gbps_frac=$(((value % 125000000) * 100 / 125000000))
                    printf "  %-20s: %s (%d.%02d Gbps)\n" "$name" "$value" "$gbps" "$gbps_frac"
                    ;;
                lotserver_gain)
                    gain_x=$((value / 10))
                    gain_frac=$((value % 10))
                    printf "  %-20s: %s (%d.%dx)\n" "$name" "$value" "$gain_x" "$gain_frac"
                    ;;
                lotserver_beta)
                    beta_val=$((value * 100 / 1024))
                    printf "  %-20s: %s (%d%% fairness)\n" "$name" "$value" "$beta_val"
                    ;;
                *)
                    printf "  %-20s: %s\n" "$name" "$value"
                    ;;
            esac
        done
    fi
    echo "═══════════════════════════════════════════════════════"
}

apply_preset() {
    PRESET=$2

    echo -e "${CYAN}Applying preset: $PRESET${NC}"

    case $PRESET in
        conservative)
            echo 125000000 > /sys/module/lotspeed/parameters/lotserver_rate
            echo 15 > /sys/module/lotspeed/parameters/lotserver_gain
            echo 16 > /sys/module/lotspeed/parameters/lotserver_min_cwnd
            echo 2000 > /sys/module/lotspeed/parameters/lotserver_max_cwnd
            echo 717 > /sys/module/lotspeed/parameters/lotserver_beta
            echo 1 > /sys/module/lotspeed/parameters/lotserver_adaptive
            echo 0 > /sys/module/lotspeed/parameters/lotserver_turbo
            echo -e "${GREEN}Applied conservative preset (1Gbps, 1.5x, safe)${NC}"
            ;;
        balanced)
            echo 625000000 > /sys/module/lotspeed/parameters/lotserver_rate
            echo 20 > /sys/module/lotspeed/parameters/lotserver_gain
            echo 16 > /sys/module/lotspeed/parameters/lotserver_min_cwnd
            echo 5000 > /sys/module/lotspeed/parameters/lotserver_max_cwnd
            echo 717 > /sys/module/lotspeed/parameters/lotserver_beta
            echo 1 > /sys/module/lotspeed/parameters/lotserver_adaptive
            echo 0 > /sys/module/lotspeed/parameters/lotserver_turbo
            echo -e "${GREEN}Applied balanced preset (5Gbps, 2.0x, adaptive)${NC}"
            ;;
        aggressive)
            echo 1250000000 > /sys/module/lotspeed/parameters/lotserver_rate
            echo 30 > /sys/module/lotspeed/parameters/lotserver_gain
            echo 32 > /sys/module/lotspeed/parameters/lotserver_min_cwnd
            echo 8000 > /sys/module/lotspeed/parameters/lotserver_max_cwnd
            echo 819 > /sys/module/lotspeed/parameters/lotserver_beta
            echo 1 > /sys/module/lotspeed/parameters/lotserver_adaptive
            echo 0 > /sys/module/lotspeed/parameters/lotserver_turbo
            echo -e "${GREEN}Applied aggressive preset (10Gbps, 3.0x, aggressive)${NC}"
            ;;
        extreme)
            echo 2500000000 > /sys/module/lotspeed/parameters/lotserver_rate
            echo 50 > /sys/module/lotspeed/parameters/lotserver_gain
            echo 50 > /sys/module/lotspeed/parameters/lotserver_min_cwnd
            echo 10000 > /sys/module/lotspeed/parameters/lotserver_max_cwnd
            echo 921 > /sys/module/lotspeed/parameters/lotserver_beta
            echo 0 > /sys/module/lotspeed/parameters/lotserver_adaptive
            echo 1 > /sys/module/lotspeed/parameters/lotserver_turbo
            echo -e "${YELLOW}⚡ Applied EXTREME preset (20Gbps, 5.0x, TURBO)${NC}"
            echo -e "${RED}WARNING: This ignores ALL congestion signals!${NC}"
            ;;
        bbr-like)
            echo 125000000 > /sys/module/lotspeed/parameters/lotserver_rate
            echo 25 > /sys/module/lotspeed/parameters/lotserver_gain
            echo 4 > /sys/module/lotspeed/parameters/lotserver_min_cwnd
            echo 10000 > /sys/module/lotspeed/parameters/lotserver_max_cwnd
            echo 717 > /sys/module/lotspeed/parameters/lotserver_beta
            echo 1 > /sys/module/lotspeed/parameters/lotserver_adaptive
            echo 0 > /sys/module/lotspeed/parameters/lotserver_turbo
            echo 0 > /sys/module/lotspeed/parameters/lotserver_verbose
            echo -e "${GREEN}Applied BBR-like preset (1G, 2.5x, probe)${NC}"
            ;;
        debug)
            echo 1 > /sys/module/lotspeed/parameters/lotserver_verbose
            echo -e "${GREEN}Debug mode enabled - verbose logging ON${NC}"
            ;;
        *)
            echo "Available presets:"
            echo "  conservative - Safe for shared networks (1G, 1.5x)"
            echo "  balanced    - Good performance (5G, 2.0x) [RECOMMENDED]"
            echo "  aggressive  - High performance (10G, 3.0x)"
            echo "  extreme     - Maximum speed (20G, 5.0x, TURBO)"
            echo "  bbr-like    - BBR-style behavior (1G, 2.5x)"
            echo "  debug       - Enable verbose debug logging"
            exit 1
            ;;
    esac
}

set_param() {
    PARAM=$2
    VALUE=$3

    if [[ -z "$PARAM" ]] || [[ -z "$VALUE" ]]; then
        echo "Usage: lotspeed set <parameter> <value>"
        echo ""
        echo "Available parameters (v$VERSION):"
        echo "  lotserver_rate     - Max rate in bytes/sec (0=auto)"
        echo "  lotserver_gain     - Gain multiplier x10 (20 = 2.0x)"
        echo "  lotserver_min_cwnd - Minimum congestion window (16)"
        echo "  lotserver_max_cwnd - Maximum congestion window (10000)"
        echo "  lotserver_beta     - Fairness factor /1024 (717 = 0.7)"
        echo "  lotserver_adaptive - Enable adaptive mode (0/1)"
        echo "  lotserver_turbo    - Enable turbo mode (0/1)"
        echo "  lotserver_verbose  - Enable verbose logging (0/1)"
        echo "  force_unload       - Force module unload (0/1)"
        echo ""
        echo "Examples:"
        echo "  lotspeed set lotserver_rate 1250000000  # 10Gbps"
        echo "  lotspeed set lotserver_gain 25          # 2.5x gain"
        echo "  lotspeed set lotserver_beta 819         # 0.8 fairness"
        echo "  lotspeed set lotserver_turbo 1          # Enable turbo"
        echo "  lotspeed set lotserver_verbose 1        # Debug logging"
        exit 1
    fi

    PARAM_FILE="/sys/module/lotspeed/parameters/$PARAM"
    if [[ -f "$PARAM_FILE" ]]; then
        OLD_VALUE=$(cat $PARAM_FILE)
        echo $VALUE > $PARAM_FILE

        # 特殊显示某些参数
        case $PARAM in
            lotserver_rate)
                gbps=$((VALUE / 125000000))
                gbps_frac=$(((VALUE % 125000000) * 100 / 125000000))
                echo -e "${GREEN}✓ Set $PARAM = $VALUE ($gbps.$gbps_frac Gbps, was: $OLD_VALUE)${NC}"
                ;;
            lotserver_gain)
                gain_x=$((VALUE / 10))
                gain_frac=$((VALUE % 10))
                echo -e "${GREEN}✓ Set $PARAM = $VALUE (${gain_x}.${gain_frac}x, was: $OLD_VALUE)${NC}"
                ;;
            lotserver_beta)
                beta_val=$((VALUE * 100 / 1024))
                echo -e "${GREEN}✓ Set $PARAM = $VALUE (${beta_val}%, was: $OLD_VALUE)${NC}"
                ;;
            *)
                echo -e "${GREEN}✓ Set $PARAM = $VALUE (was: $OLD_VALUE)${NC}"
                ;;
        esac
    else
        echo -e "${RED}Error: Parameter $PARAM not found${NC}"
        exit 1
    fi
}

case "$ACTION" in
    start)
        if lsmod | grep -q lotspeed; then
            echo -e "${YELLOW}LotSpeed v$VERSION module is already loaded${NC}"
            CURRENT=$(sysctl -n net.ipv4.tcp_congestion_control)
            if [[ "$CURRENT" != "lotspeed" ]]; then
                echo -e "${CYAN}Switching algorithm to lotspeed...${NC}"
                sysctl -w net.ipv4.tcp_congestion_control=lotspeed >/dev/null
            fi
        else
            modprobe lotspeed 2>/dev/null || insmod $INSTALL_DIR/lotspeed.ko
            sysctl -w net.ipv4.tcp_congestion_control=lotspeed >/dev/null
        fi
        echo -e "${GREEN}✓ LotSpeed v$VERSION is active${NC}"
        ;;
    stop)
        safe_stop
        ;;
    restart)
        $0 stop
        sleep 1
        $0 start
        ;;
    status)
        show_status
        ;;
    preset)
        apply_preset $@
        ;;
    set)
        set_param $@
        ;;
    log|logs)
        dmesg | grep lotspeed | tail -50
        ;;
    monitor)
        dmesg -w | grep --color=always lotspeed
        ;;
    uninstall)
        safe_uninstall
        ;;
    connections|conns)
        echo -e "${CYAN}Active connections using LotSpeed:${NC}"
        ss -tin | grep lotspeed || echo "No active connections"
        ;;
    benchmark|bench)
        echo -e "${CYAN}Running quick network benchmark...${NC}"
        echo "Testing download speed with curl:"
        curl -o /dev/null -w "Time: %{time_total}s, Speed: %{speed_download} bytes/sec\n" \
            http://speedtest.tele2.net/500MB.zip 2>/dev/null || \
            echo "Benchmark failed - no suitable test server"
        ;;
    *)
        echo "╔════════════════════════════════════════════════════════╗"
        echo "║        LotSpeed v$VERSION Management Tool                   ║"
        echo "║        公路超跑 完整整合版                             ║"
        echo "║        Created by uk0 @ $CURRENT_TIME            ║"
        echo "╚════════════════════════════════════════════════════════╝"
        echo ""
        echo "Usage: lotspeed {command} [options]"
        echo ""
        echo "Commands:"
        echo "  start       - Start LotSpeed"
        echo "  stop        - Stop LotSpeed (switch to default algorithm)"
        echo "  restart     - Restart LotSpeed"
        echo "  status      - Show current status and parameters"
        echo "  preset      - Apply preset configuration"
        echo "  set         - Set parameter value"
        echo "  connections - Show active connections"
        echo "  log         - Show recent logs"
        echo "  monitor     - Monitor logs in real-time"
        echo "  benchmark   - Run simple speed test"
        echo "  uninstall   - Completely uninstall LotSpeed"
        echo ""
        echo "Presets:"
        echo "  lotspeed preset conservative  - 1Gbps, 1.5x gain, safe"
        echo "  lotspeed preset balanced      - 5Gbps, 2.0x gain [RECOMMENDED]"
        echo "  lotspeed preset aggressive    - 10Gbps, 3.0x gain"
        echo "  lotspeed preset extreme       - 20Gbps, 5.0x gain, TURBO"
        echo "  lotspeed preset bbr-like      - BBR-style behavior"
        echo "  lotspeed preset debug         - Enable debug logging"
        echo ""
        echo "Examples (v$VERSION new features):"
        echo "  lotspeed status                          # Check status"
        echo "  lotspeed preset balanced                 # Apply balanced preset"
        echo "  lotspeed set lotserver_rate 0            # Auto-detect rate"
        echo "  lotspeed set lotserver_gain 25           # Set 2.5x gain"
        echo "  lotspeed set lotserver_beta 819          # Set 80% fairness"
        echo "  lotspeed set lotserver_turbo 1           # Enable turbo mode"
        echo "  lotspeed set lotserver_verbose 1         # Enable debug log"
        echo "  lotspeed set lotserver_adaptive 1        # Enable adaptive"
        echo "  lotspeed set force_unload 1              # Force unload"
        echo "  lotspeed monitor                         # Watch real-time logs"
        echo ""
        echo "Advanced Examples:"
        echo "  # For 100Mbps VPS:"
        echo "  lotspeed set lotserver_rate 12500000     # 100Mbps limit"
        echo "  lotspeed set lotserver_gain 18           # 1.8x gain"
        echo ""
        echo "  # For 10Gbps dedicated server:"
        echo "  lotspeed set lotserver_rate 1250000000   # 10Gbps"
        echo "  lotspeed set lotserver_gain 30           # 3.0x gain"
        echo "  lotspeed set lotserver_max_cwnd 10000    # Large cwnd"
        echo ""
        echo "  # For lossy network (packet loss):"
        echo "  lotspeed set lotserver_beta 921          # 90% (gentle)"
        echo "  lotspeed set lotserver_turbo 1           # Ignore loss"
        echo ""
        echo "Note: v$VERSION includes ProbeRTT, Smart Startup, ECN support"
        exit 1
        ;;
esac
SCRIPT_EOF

    chmod +x /usr/local/bin/lotspeed
    log_success "Management script created at /usr/local/bin/lotspeed"
}

# 显示配置信息
show_info() {
    echo ""
    echo -e "${GREEN}═══════════════════════════════════════════════════════${NC}"
    echo -e "${GREEN}       LotSpeed v$VERSION Installation Complete!${NC}"
    echo -e "${GREEN}              公路超跑 完整整合版${NC}"
    echo -e "${GREEN}═══════════════════════════════════════════════════════${NC}"
    echo ""

    # 显示当前状态
    /usr/local/bin/lotspeed status

    echo ""
    echo -e "${CYAN}Quick Start Commands:${NC}"
    echo "───────────────────────────────────────────────────────"
    echo -e "  ${WHITE}lotspeed status${NC}           - Check current status"
    echo -e "  ${WHITE}lotspeed preset balanced${NC}  - Apply balanced preset"
    echo -e "  ${WHITE}lotspeed preset bbr-like${NC}  - BBR-style behavior"
    echo -e "  ${WHITE}lotspeed preset extreme${NC}   - Maximum performance"
    echo -e "  ${WHITE}lotspeed monitor${NC}          - Monitor logs"
    echo -e "  ${WHITE}lotspeed set lotserver_verbose 1${NC} - Enable debug"
    echo ""
    echo -e "${YELLOW}Recommended Settings:${NC}"
    echo "───────────────────────────────────────────────────────"
    echo "  • For VPS/Cloud:     lotspeed preset balanced"
    echo "  • For Dedicated:     lotspeed preset aggressive"
    echo "  • For Testing:       lotspeed preset extreme"
    echo "  • For Debugging:     lotspeed preset debug"
    echo ""
    echo -e "${MAGENTA}New in v$VERSION:${NC}"
    echo "───────────────────────────────────────────────────────"
    echo "  ✨ Smart Startup - Intelligent slow-start exit"
    echo "  ✨ ProbeRTT - Periodic RTT measurement"
    echo "  ✨ ECN Support - Explicit Congestion Notification"
    echo "  ✨ Fairness Beta - Configurable backoff factor"
    echo "  ✨ 5-State Machine - STARTUP/PROBING/CRUISING/AVOIDING/PROBE_RTT"
    echo ""
    echo -e "${GREEN}Installation Details:${NC}"
    echo "───────────────────────────────────────────────────────"
    echo "  Install Path:    $INSTALL_DIR"
    echo "  Management Tool: /usr/local/bin/lotspeed"
    echo "  Kernel Module:   /lib/modules/$(uname -r)/kernel/net/ipv4/lotspeed.ko"
    echo "  Install Time:    $CURRENT_TIME UTC"
    echo "  Installer:       $CURRENT_USER"
    echo ""
    echo -e "${MAGENTA}GitHub: https://github.com/$GITHUB_REPO${NC}"
    echo -e "${GREEN}═══════════════════════════════════════════════════════${NC}"

    # 最后的提醒
    echo ""
    echo -e "${YELLOW}⚠ Important Notes:${NC}"
    echo "  • LotSpeed v$VERSION is now active as default TCP algorithm"
    echo "  • Use 'lotspeed preset balanced' for most scenarios"
    echo "  • Beta parameter controls fairness (717=70%, 921=90%)"
    echo "  • Monitor state transitions: lotspeed monitor"
    echo "  • Check connections: ss -tin | grep lotspeed"
}

# 错误处理
error_exit() {
    log_error "$1"
    echo -e "${RED}Installation failed. Check logs above for details.${NC}"
    exit 1
}

# 主函数
main() {
    clear
    print_banner

    check_root || error_exit "Root check failed"
    check_system || error_exit "System check failed"
    detect_kernel_build_toolchain

    if [[ "$ACTION" == "-u" ]]; then
        echo -e "${CYAN}Starting dependency removal at $CURRENT_TIME UTC${NC}"
        echo -e "${CYAN}Installer: $CURRENT_USER${NC}"
        echo ""
        uninstall_dependencies || error_exit "Dependency removal failed"
        exit 0
    fi

    echo -e "${CYAN}Starting installation at $CURRENT_TIME UTC${NC}"
    echo -e "${CYAN}Installer: $CURRENT_USER${NC}"
    echo -e "${CYAN}Version: $VERSION (公路超跑 完整整合版)${NC}"
    echo ""

    # 执行安装步骤
    install_dependencies || error_exit "Dependency installation failed"
    download_source || error_exit "Source download failed"
    compile_module || error_exit "Module compilation failed"
    load_module || error_exit "Module loading failed"
    create_management_script || error_exit "Script creation failed"

    # 显示完成信息
    show_info

    # 记录安装日志
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] LotSpeed v$VERSION installed by $CURRENT_USER" >> /var/log/lotspeed_install.log
}

# 执行主函数
main