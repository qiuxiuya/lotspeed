#!/bin/bash
#
# LotSpeed v5.6 - ml-tcp Auto-Scaling Edition (UI Enhanced)
# Author: uk0 @ 2025-11-23
# GitHub: https://github.com/uk0/lotspeed
#
# Usage:
#   curl -fsSL https://raw.githubusercontent.com/uk0/lotspeed/ml-tcp/install.sh | sudo bash
#

set -e

# ================= 配置区域 =================
GITHUB_REPO="qiuxiuya/lotspeed"
GITHUB_BRANCH="ml-tcp"
INSTALL_DIR="/opt/lotspeed"
MODULE_NAME="lotspeed"
VERSION="5.6"
CURRENT_TIME=$(date '+%Y-%m-%d %H:%M:%S')
CURRENT_USER=$(whoami)
ACTION="${1:-install}"
MAKE_ARGS=()
KERNEL_CONFIG=""
KERNEL_USES_LLVM=0
KERNEL_CLANG_MAJOR=""
LLVM_MAKE_VALUE="1"

# ================= 颜色定义 =================
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
MAGENTA='\033[0;35m'
CYAN='\033[0;36m'
WHITE='\033[1;37m'
NC='\033[0m' # No Color

# ================= UI 核心算法 (安装脚本用) =================
BOX_WIDTH=70

# 计算视觉宽度 (忽略颜色代码, 中文/全角符号算2, 英文算1)
get_width() {
    local str="$1"
    # 移除 ANSI 颜色代码
    local clean_str=$(echo -e "$str" | sed -r "s/\x1B\[([0-9]{1,2}(;[0-9]{1,2})?)?[mGK]//g")

    local width=0
    local len=${#clean_str}

    for ((i=0; i<len; i++)); do
        local char="${clean_str:$i:1}"
        # 获取字符的 ASCII 值，简单的判断方法
        local ord=$(printf "%d" "'$char" 2>/dev/null || echo 128)
        if [ "$ord" -gt 127 ]; then
            ((width+=2))
        else
            ((width+=1))
        fi
    done
    echo $width
}

# 打印重复字符
repeat_char() {
    local char="$1"
    local count="$2"
    if [ "$count" -gt 0 ]; then
        printf "%0.s$char" $(seq 1 $count)
    fi
}

# 绘制盒子顶部
print_box_top() {
    local color="${1:-$CYAN}"
    echo -ne "${color}╔"
    repeat_char "═" $((BOX_WIDTH - 2))
    echo -e "╗${NC}"
}

# 绘制盒子分隔线
print_box_div() {
    local color="${1:-$CYAN}"
    echo -ne "${color}╟"
    repeat_char "─" $((BOX_WIDTH - 2))
    echo -e "╢${NC}"
}

# 绘制盒子底部
print_box_bottom() {
    local color="${1:-$CYAN}"
    echo -ne "${color}╚"
    repeat_char "═" $((BOX_WIDTH - 2))
    echo -e "╝${NC}"
}

# 绘制内容行 (支持 align=left|center)
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
║                 ML-TCP Auto-Scaling Edition                          ║
║                       Version 5.6rc                                  ║
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
        # 尝试安装 clang 作为备用编译器（如果 gcc 版本过旧）
        local gcc_ver=$(gcc -dumpversion 2>/dev/null | cut -d. -f1)
        if [[ -n "$gcc_ver" ]] && [[ "$gcc_ver" -lt 8 ]]; then
            log_info "GCC version is old, installing clang as backup..."
            yum install -y clang 2>/dev/null || log_warn "Could not install clang"
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
        # 尝试安装 clang 作为备用编译器（如果 gcc 版本过旧）
        local gcc_ver=$(gcc -dumpversion 2>/dev/null | cut -d. -f1)
        if [[ -n "$gcc_ver" ]] && [[ "$gcc_ver" -lt 8 ]]; then
            log_info "GCC version is old, installing clang as backup..."
            apt-get install -y clang 2>/dev/null || log_warn "Could not install clang"
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

download_source() {
    log_info "Downloading LotSpeed v$VERSION source code..."

    # 创建安装目录
    mkdir -p $INSTALL_DIR
    cd $INSTALL_DIR

    # 下载源代码
    curl -fsSL "https://raw.githubusercontent.com/$GITHUB_REPO/$GITHUB_BRANCH/lotspeed.c" -o lotspeed.c || {
        log_error "Failed to download lotspeed.c"
        exit 1
    }

    # 下载 Makefile
    curl -fsSL "https://raw.githubusercontent.com/$GITHUB_REPO/$GITHUB_BRANCH/Makefile" -o Makefile || {
        log_error "Failed to download Makefile"
        exit 1
    }

    log_success "Source code downloaded"
}

detect_compiler() {
    # 检测可用的编译器
    local gcc_version=""
    local clang_version=""
    local preferred_cc=""

    if command -v gcc &>/dev/null; then
        gcc_version=$(gcc -dumpversion 2>/dev/null | cut -d. -f1)
        log_info "Detected GCC version: $gcc_version"
    fi

    if command -v clang &>/dev/null; then
        clang_version=$(clang --version 2>/dev/null | head -1 | grep -oE '[0-9]+\.[0-9]+' | head -1)
        log_info "Detected Clang version: $clang_version"
    fi

    # 优先使用 gcc，但如果版本过旧（<8）且有 clang，使用 clang
    if [[ -n "$gcc_version" ]]; then
        if [[ "$gcc_version" -ge 8 ]]; then
            preferred_cc="gcc"
        elif [[ -n "$clang_version" ]]; then
            log_warn "GCC version $gcc_version is old, using Clang instead"
            preferred_cc="clang"
        else
            preferred_cc="gcc"
        fi
    elif [[ -n "$clang_version" ]]; then
        preferred_cc="clang"
    else
        log_error "No C compiler found. Please install gcc or clang."
        exit 1
    fi

    echo "$preferred_cc"
}

detect_make_args() {
    if [[ $KERNEL_USES_LLVM -eq 1 ]]; then
        log_info "Enabling make ${MAKE_ARGS[*]}"
    else
        log_info "Using default make parameters"
    fi
}

compile_module() {
    log_info "Compiling LotSpeed v$VERSION kernel module..."

    cd $INSTALL_DIR
    detect_make_args
    make "${MAKE_ARGS[@]}" clean >/dev/null 2>&1

    local compiler=$(detect_compiler)
    local compile_success=0
    local compile_output=""

    # 第一次尝试：使用检测到的编译器
    log_info "Trying compilation with $compiler..."
    if [[ "$compiler" == "clang" ]]; then
        compile_output=$(make "${MAKE_ARGS[@]}" CC=clang 2>&1)
        if [[ $? -eq 0 ]] && [[ -f lotspeed.ko ]]; then
            compile_success=1
        fi
    else
        compile_output=$(make "${MAKE_ARGS[@]}" 2>&1)
        if [[ $? -eq 0 ]] && [[ -f lotspeed.ko ]]; then
            compile_success=1
        fi
    fi

    # 如果 gcc 编译失败，检查是否是不支持的选项错误，尝试 clang
    if [[ $compile_success -eq 0 ]]; then
        if echo "$compile_output" | grep -qE "unrecognized command-line option|unknown argument"; then
            log_warn "Compiler option error detected, trying with clang..."
            if command -v clang &>/dev/null; then
                make "${MAKE_ARGS[@]}" clean >/dev/null 2>&1
                compile_output=$(make "${MAKE_ARGS[@]}" CC=clang 2>&1)
                if [[ $? -eq 0 ]] && [[ -f lotspeed.ko ]]; then
                    compile_success=1
                    log_success "Compilation succeeded with clang"
                fi
            fi
        fi
    fi

    # 如果仍然失败，显示错误信息
    if [[ $compile_success -eq 0 ]]; then
        log_error "Compilation failed. Error output:"
        echo "$compile_output" | tail -30
        echo ""
        log_error "Possible solutions:"
        echo "  1. Update your gcc to version 8 or higher"
        echo "  2. Install clang: apt install clang (Debian/Ubuntu) or yum install clang (CentOS)"
        echo "  3. Check if kernel headers are properly installed"
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

# ================= 创建管理脚本 (嵌入 UI 算法) =================
create_management_script() {
    log_info "Creating management script..."

    # 使用 'SCRIPT_EOF' 避免变量在此时展开，而是在生成的脚本运行时展开
    cat > /usr/local/bin/lotspeed << 'SCRIPT_EOF'
#!/bin/bash
# LotSpeed Management Script (Auto-Aligned UI)

ACTION=$1
INSTALL_DIR="/opt/lotspeed"
VERSION="5.6"

# 颜色
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
MAGENTA='\033[0;35m'
WHITE='\033[1;37m'
BOLD='\033[1m'
NC='\033[0m'

# ================= UI 算法 (嵌入) =================
BOX_WIDTH=70

# 计算视觉宽度
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

# 打印键值对行 (Left Key ...... Right Value)
print_kv_row() {
    local key="$1"
    local val="$2"
    local color="${3:-$CYAN}"

    local key_width=$(get_width "$key")
    local val_width=$(get_width "$val")

    # 左右各1空格Padding + 中间
    local available=$((BOX_WIDTH - 4))
    local padding=$((available - key_width - val_width))

    [ $padding -lt 1 ] && padding=1

    echo -ne "${color}║${NC} $key"
    repeat_char " " $padding
    echo -e "$val ${color}║${NC}"
}

# ================= 业务逻辑 =================

format_bytes() {
    local bytes=$1
    if [[ $bytes -ge 1000000000 ]]; then
        echo "$(echo "scale=2; $bytes/1000000000" | bc) GB/s"
    elif [[ $bytes -ge 1000000 ]]; then
        echo "$(echo "scale=2; $bytes/1000000" | bc) MB/s"
    elif [[ $bytes -ge 1000 ]]; then
        echo "$(echo "scale=2; $bytes/1000" | bc) KB/s"
    else
        echo "$bytes B/s"
    fi
}

format_bps() {
    local bytes=$1
    local bits=$((bytes * 8))
    if [[ $bits -ge 1000000000 ]]; then
        echo "$(echo "scale=2; $bits/1000000000" | bc) Gbps"
    elif [[ $bits -ge 1000000 ]]; then
        echo "$(echo "scale=2; $bits/1000000" | bc) Mbps"
    elif [[ $bits -ge 1000 ]]; then
        echo "$(echo "scale=2; $bits/1000" | bc) Kbps"
    else
        echo "$bits bps"
    fi
}

get_default_congestion_control() {
    AVAILABLE=$(sysctl net.ipv4.tcp_available_congestion_control | awk -F= '{print $2}')
    if echo "$AVAILABLE" | grep -q "cubic"; then echo "cubic";
    elif echo "$AVAILABLE" | grep -q "reno"; then echo "reno";
    elif echo "$AVAILABLE" | grep -q "bbr"; then echo "bbr";
    else echo "$AVAILABLE" | awk '{print $1}'; fi
}

show_status() {
    print_box_top
    print_box_row "LotSpeed v$VERSION Status (ML-TCP)" "center"
    print_box_div

    # 检查模块状态
    if lsmod | grep -q lotspeed; then
        print_kv_row "Module Status" "${GREEN}Loaded${NC}"

        REF_COUNT=$(lsmod | grep lotspeed | awk '{print $3}')
        print_kv_row "Reference Count" "${CYAN}$REF_COUNT${NC}"

        # 修复：确保 ACTIVE_CONNS 只是一个数字，没有换行
        ACTIVE_CONNS=$(ss -tin 2>/dev/null | grep -c lotspeed || echo "0")
        # 去除可能的换行和空格
        ACTIVE_CONNS=$(echo $ACTIVE_CONNS | tr -d '\n' | tr -d ' ')
        print_kv_row "Active Connections" "${CYAN}$ACTIVE_CONNS${NC}"
    else
        print_kv_row "Module Status" "${RED}○ Not Loaded${NC}"
        print_box_bottom
        return
    fi

    # 检查当前算法
    CURRENT=$(sysctl -n net.ipv4.tcp_congestion_control)
    if [[ "$CURRENT" == "lotspeed" ]]; then
        print_kv_row "Active Algorithm" "${GREEN}lotspeed${NC}"
    else
        print_kv_row "Active Algorithm" "${YELLOW}$CURRENT${NC}"
    fi

    print_box_div
    print_box_row "Current Parameters" "center"
    print_box_div

    if [[ -d /sys/module/lotspeed/parameters ]]; then
        for param in lotserver_rate lotserver_min_cwnd lotserver_max_cwnd lotserver_beta \
                     lotserver_turbo lotserver_safe_mode lotserver_fast_alpha lotserver_fast_gamma \
                     lotserver_fast_ss_exit lotserver_hd_enable lotserver_hd_thresh_us \
                     lotserver_hd_ref_us lotserver_hd_gamma_boost lotserver_hd_alpha_boost \
                     lotserver_brave_enable lotserver_brave_rtt_pct lotserver_brave_hold_ms \
                     lotserver_brave_floor_pct lotserver_brave_push_pct; do

            param_file="/sys/module/lotspeed/parameters/$param"
            if [[ -f "$param_file" ]]; then
                value=$(cat $param_file 2>/dev/null)
                case $param in
                    lotserver_rate)
                        formatted=$(format_bytes $value)
                        bps=$(format_bps $value)
                        print_kv_row "Global Rate Limit" "$formatted ($bps)"
                        ;;
                    lotserver_beta)
                        beta_val=$((value * 100 / 1024))
                        print_kv_row "Fairness (Beta)" "${beta_val}%"
                        ;;
                    lotserver_min_cwnd)
                        print_kv_row "Min CWND" "$value packets"
                        ;;
                    lotserver_max_cwnd)
                        print_kv_row "Max CWND" "$value packets"
                        ;;
                    lotserver_turbo)
                        if [[ "$value" == "Y" ]] || [[ "$value" == "1" ]]; then
                            print_kv_row "Turbo Mode" "${YELLOW}Enabled ⚡${NC}"
                        else
                            print_kv_row "Turbo Mode" "Disabled"
                        fi
                        ;;
                    lotserver_safe_mode)
                        if [[ "$value" == "Y" ]] || [[ "$value" == "1" ]]; then
                            print_kv_row "Safe Mode" "${GREEN}Enabled${NC}"
                        else
                            print_kv_row "Safe Mode" "Disabled"
                        fi
                        ;;
                    lotserver_fast_alpha)
                        print_kv_row "FAST Alpha" "$value packets"
                        ;;
                    lotserver_fast_gamma)
                        print_kv_row "FAST Gamma" "${value}%"
                        ;;
                    lotserver_fast_ss_exit)
                        print_kv_row "SS Exit Threshold" "${value}%"
                        ;;
                    lotserver_hd_enable)
                        if [[ "$value" == "Y" ]] || [[ "$value" == "1" ]]; then
                            print_kv_row "High-Delay Mode" "${GREEN}Enabled${NC}"
                        else
                            print_kv_row "High-Delay Mode" "Disabled"
                        fi
                        ;;
                    lotserver_hd_thresh_us)
                        print_kv_row "HD Threshold" "${value}us"
                        ;;
                    lotserver_hd_ref_us)
                        print_kv_row "HD Reference RTT" "${value}us"
                        ;;
                    lotserver_hd_gamma_boost)
                        print_kv_row "HD Gamma Boost" "${value}%"
                        ;;
                    lotserver_hd_alpha_boost)
                        print_kv_row "HD Alpha Boost" "$value packets"
                        ;;
                    lotserver_brave_enable)
                        if [[ "$value" == "Y" ]] || [[ "$value" == "1" ]]; then
                            print_kv_row "Brave Mode" "${GREEN}Enabled${NC}"
                        else
                            print_kv_row "Brave Mode" "Disabled"
                        fi
                        ;;
                    lotserver_brave_rtt_pct)
                        print_kv_row "Brave RTT Tolerance" "${value}%"
                        ;;
                    lotserver_brave_hold_ms)
                        print_kv_row "Brave Hold Time" "${value}ms"
                        ;;
                    lotserver_brave_floor_pct)
                        print_kv_row "Brave Floor" "${value}%"
                        ;;
                    lotserver_brave_push_pct)
                        print_kv_row "Brave Push" "${value}%"
                        ;;
                esac
            fi
        done
    fi
    print_box_bottom
}

apply_preset() {
    PRESET=$2

    # 模拟设置参数 (实际写入 sysfs)
    set_val() {
        echo $2 > /sys/module/lotspeed/parameters/$1 2>/dev/null
    }

    print_box_top
    print_box_row "Applying Preset: $PRESET" "center"
    print_box_div

    case $PRESET in
        conservative)
            set_val lotserver_rate 125000000
            set_val lotserver_min_cwnd 16
            set_val lotserver_max_cwnd 15000
            set_val lotserver_beta 717
            set_val lotserver_turbo 0
            set_val lotserver_safe_mode 1
            set_val lotserver_fast_alpha 15
            set_val lotserver_fast_gamma 40
            set_val lotserver_fast_ss_exit 20
            set_val lotserver_hd_enable 1
            set_val lotserver_brave_enable 1
            set_val lotserver_brave_rtt_pct 20
            print_box_row "Applied: Conservative (1Gbps, Safe)" "left"
            ;;
        balanced)
            set_val lotserver_rate 256000000
            set_val lotserver_min_cwnd 16
            set_val lotserver_max_cwnd 15000
            set_val lotserver_beta 616
            set_val lotserver_turbo 0
            set_val lotserver_safe_mode 1
            set_val lotserver_fast_alpha 20
            set_val lotserver_fast_gamma 50
            set_val lotserver_fast_ss_exit 25
            set_val lotserver_hd_enable 1
            set_val lotserver_brave_enable 1
            set_val lotserver_brave_rtt_pct 25
            print_box_row "Applied: Balanced (2.5Gbps, FAST)" "left"
            ;;
        aggressive)
            set_val lotserver_rate 500000000
            set_val lotserver_min_cwnd 16
            set_val lotserver_max_cwnd 20000
            set_val lotserver_beta 512
            set_val lotserver_turbo 0
            set_val lotserver_safe_mode 1
            set_val lotserver_fast_alpha 30
            set_val lotserver_fast_gamma 60
            set_val lotserver_fast_ss_exit 30
            set_val lotserver_hd_enable 1
            set_val lotserver_hd_gamma_boost 30
            set_val lotserver_brave_enable 1
            set_val lotserver_brave_push_pct 12
            print_box_row "Applied: Aggressive (4Gbps, High Push)" "left"
            ;;
        *)
            print_box_row "Unknown preset: $PRESET" "left" "${RED}"
            print_box_div
            print_box_row "Available: conservative, balanced, aggressive" "left"
            print_box_bottom
            exit 1
            ;;
    esac
    print_box_bottom
}

set_param() {
    PARAM=$2
    VALUE=$3
    if [[ -z "$PARAM" ]] || [[ -z "$VALUE" ]]; then
        print_box_top
        print_box_row "Parameter Set Error" "center" "${RED}"
        print_box_div
        print_box_row "Usage: lotspeed set <parameter> <value>" "left"
        print_box_row "Example: lotspeed set lotserver_rate 125000000" "left"
        print_box_row "Example: lotspeed set lotserver_min_cwnd 16" "left"
        print_box_row "Example: lotspeed set lotserver_max_cwnd 15000" "left"
        print_box_row "Example: lotspeed set lotserver_beta 616" "left"
        print_box_row "Example: lotspeed set lotserver_fast_alpha 20" "left"
        print_box_row "Example: lotspeed set lotserver_fast_gamma 50" "left"
        print_box_row "Example: lotspeed set lotserver_turbo 1/0" "left"
        print_box_row "Example: lotspeed set lotserver_safe_mode 1/0" "left"
        print_box_row "Example: lotspeed set lotserver_brave_enable 1/0" "left"
        print_box_bottom
        exit 1
    fi

    PARAM_FILE="/sys/module/lotspeed/parameters/$PARAM"
    if [[ -f "$PARAM_FILE" ]]; then
        echo $VALUE > $PARAM_FILE 2>/dev/null || {
             echo -e "${RED}Error setting value${NC}"; exit 1;
        }
        print_box_top "${GREEN}"
        print_box_row "Parameter Updated" "center" "${GREEN}"
        print_box_div "${GREEN}"
        print_kv_row "$PARAM" "$VALUE" "${GREEN}"
        print_box_bottom "${GREEN}"
    else
        echo -e "${RED}Parameter not found${NC}"
    fi
}

case "$ACTION" in
    start)
        modprobe lotspeed 2>/dev/null || insmod $INSTALL_DIR/lotspeed.ko
        sysctl -w net.ipv4.tcp_congestion_control=lotspeed >/dev/null
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
        print_kv_row "Current Algo" "$DEFAULT_ALGO" "${YELLOW}"
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
    preset)
        apply_preset $@
        ;;
    set)
        set_param $@
        ;;
    log|logs)
        print_box_top
        print_box_row "Kernel Logs (Last 10)" "center"
        print_box_bottom
        dmesg | grep -i lotspeed | tail -10
        ;;
    monitor)
        echo -e "${CYAN}Monitoring logs (Ctrl+C to stop)...${NC}"
        dmesg -w | grep --color=always -i lotspeed
        ;;
    uninstall)
        print_box_top "${MAGENTA}"
        print_box_row "LotSpeed v$VERSION Uninstaller" "center" "${MAGENTA}"
        print_box_div "${MAGENTA}"

        # 停止算法
        DEFAULT_ALGO=$(get_default_congestion_control)
        print_box_row "Switching to $DEFAULT_ALGO..." "left" "${MAGENTA}"
        sysctl -w net.ipv4.tcp_congestion_control=$DEFAULT_ALGO >/dev/null 2>&1

        # 尝试卸载模块
        if rmmod lotspeed 2>/dev/null; then
            print_kv_row "Module Unload" "${GREEN}Success${NC}" "${MAGENTA}"
        else
            print_kv_row "Module Unload" "${YELLOW}In Use${NC}" "${MAGENTA}"
            print_box_div "${MAGENTA}"
            print_box_row "${YELLOW}Module is still loaded in memory ${NC}" "center" "${MAGENTA}"
            print_box_row "${YELLOW}Active connections are preventing unload${NC}" "center" "${MAGENTA}"
            print_box_row "${RED}Clean everything after reboot${NC}" "center" "${MAGENTA}"
            print_box_div "${MAGENTA}"
        fi

        # 删除文件
        print_box_row "Removing files..." "left" "${MAGENTA}"
        rm -rf $INSTALL_DIR
        rm -f /etc/modules-load.d/lotspeed.conf
        rm -f /lib/modules/$(uname -r)/kernel/net/ipv4/lotspeed.ko
        depmod -a
        sed -i '/net.ipv4.tcp_congestion_control=lotspeed/d' /etc/sysctl.conf

        print_kv_row "Config Files" "${GREEN}Removed${NC}" "${MAGENTA}"
        print_kv_row "Startup Scripts" "${GREEN}Removed${NC}" "${MAGENTA}"

        # 最终检查 - 修复这里的对齐问题
        print_box_div "${MAGENTA}"
        if lsmod | grep -q lotspeed; then
            # 内嵌的重启提示框
            print_box_row "" "center" "${MAGENTA}"
            print_box_row "${RED} ${NC}" "center" "${MAGENTA}"
            print_box_row "${RED}REBOOT REQUIRED{NC}" "center" "${MAGENTA}"
            print_box_row "${RED}Module will be completely removed${NC}" "center" "${MAGENTA}"
            print_box_row "${RED}after system reboot.${NC}" "center" "${MAGENTA}"
            print_box_row "" "center" "${MAGENTA}"
        else
            print_box_row "${GREEN}✅ LotSpeed Completely Uninstalled!${NC}" "center" "${MAGENTA}"
        fi
        print_box_bottom "${MAGENTA}"

        # 删除自己
        rm -f /usr/local/bin/lotspeed
        rm -f /etc/lotspeed/config.conf
        rm -f /etc/systemd/system/lotspeed-config.service
        systemctl daemon-reload 2>/dev/null || true
        ;;
    save)
        CONFIG_DIR="/etc/lotspeed"
        CONFIG_FILE="$CONFIG_DIR/config.conf"

        mkdir -p "$CONFIG_DIR"

        print_box_top "${GREEN}"
        print_box_row "Saving LotSpeed Configuration" "center" "${GREEN}"
        print_box_div "${GREEN}"

        if [[ ! -d /sys/module/lotspeed/parameters ]]; then
            print_box_row "${RED}Error: Module not loaded${NC}" "center" "${GREEN}"
            print_box_bottom "${GREEN}"
            exit 1
        fi

        # 保存所有参数到配置文件
        echo "# LotSpeed Configuration" > "$CONFIG_FILE"
        echo "# Generated: $(date '+%Y-%m-%d %H:%M:%S')" >> "$CONFIG_FILE"
        echo "" >> "$CONFIG_FILE"

        for param in lotserver_rate lotserver_min_cwnd lotserver_max_cwnd lotserver_beta \
                     lotserver_turbo lotserver_safe_mode lotserver_fast_alpha lotserver_fast_gamma \
                     lotserver_fast_ss_exit lotserver_hd_enable lotserver_hd_thresh_us \
                     lotserver_hd_ref_us lotserver_hd_gamma_boost lotserver_hd_alpha_boost \
                     lotserver_brave_enable lotserver_brave_rtt_pct lotserver_brave_hold_ms \
                     lotserver_brave_floor_pct lotserver_brave_push_pct; do
            param_file="/sys/module/lotspeed/parameters/$param"
            if [[ -f "$param_file" ]]; then
                value=$(cat "$param_file" 2>/dev/null)
                echo "$param=$value" >> "$CONFIG_FILE"
            fi
        done

        print_kv_row "Config File" "$CONFIG_FILE" "${GREEN}"

        # 创建 systemd 服务以在启动时恢复配置
        cat > /etc/systemd/system/lotspeed-config.service << 'SERVICE_EOF'
[Unit]
Description=LotSpeed Configuration Restore
After=network.target
ConditionPathExists=/sys/module/lotspeed/parameters

[Service]
Type=oneshot
ExecStart=/usr/local/bin/lotspeed load
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
SERVICE_EOF

        systemctl daemon-reload
        systemctl enable lotspeed-config.service 2>/dev/null

        print_kv_row "Systemd Service" "Enabled" "${GREEN}"
        print_box_div "${GREEN}"
        print_box_row "Config will be restored on reboot" "center" "${GREEN}"
        print_box_bottom "${GREEN}"
        ;;
    load)
        CONFIG_FILE="/etc/lotspeed/config.conf"

        print_box_top "${CYAN}"
        print_box_row "Loading LotSpeed Configuration" "center" "${CYAN}"
        print_box_div "${CYAN}"

        if [[ ! -f "$CONFIG_FILE" ]]; then
            print_box_row "${RED}Error: Config file not found${NC}" "center" "${CYAN}"
            print_box_row "Run 'lotspeed save' first" "center" "${CYAN}"
            print_box_bottom "${CYAN}"
            exit 1
        fi

        if [[ ! -d /sys/module/lotspeed/parameters ]]; then
            print_box_row "${RED}Error: Module not loaded${NC}" "center" "${CYAN}"
            print_box_bottom "${CYAN}"
            exit 1
        fi

        # 从配置文件加载参数
        load_count=0
        while IFS='=' read -r param value; do
            # 跳过注释和空行
            [[ "$param" =~ ^#.*$ ]] && continue
            [[ -z "$param" ]] && continue

            param_file="/sys/module/lotspeed/parameters/$param"
            if [[ -f "$param_file" ]]; then
                echo "$value" > "$param_file" 2>/dev/null && load_count=$((load_count + 1))
            fi
        done < "$CONFIG_FILE"

        print_kv_row "Parameters Loaded" "$load_count" "${CYAN}"
        print_box_bottom "${CYAN}"
        ;;
    *)
        print_box_top
        print_box_row "LotSpeed v$VERSION Management" "center"
        print_box_div
        print_kv_row "start" "Start LotSpeed"
        print_kv_row "stop" "Stop LotSpeed"
        print_kv_row "restart" "Restart LotSpeed"
        print_kv_row "status" "Check Status"
        print_kv_row "preset [name]" "Apply Preset"
        print_kv_row "set [k] [v]" "Set Parameter"
        print_kv_row "save" "Save Config (persist reboot)"
        print_kv_row "load" "Load Saved Config"
        print_kv_row "monitor" "Live Logs"
        print_kv_row "uninstall" "Remove Completely"
        print_box_div
        print_box_row "Presets: conservative, balanced, aggressive" "left"
        print_box_bottom
        exit 1
        ;;
esac
SCRIPT_EOF

    chmod +x /usr/local/bin/lotspeed
    log_success "Management script created at /usr/local/bin/lotspeed"
}

print_kv_row() {
    local key="$1"
    local val="$2"
    local color="${3:-$CYAN}"

    local key_width=$(get_width "$key")
    local val_width=$(get_width "$val")

    # 左右各1空格Padding + 中间
    local available=$((BOX_WIDTH - 4))
    local padding=$((available - key_width - val_width))

    [ $padding -lt 1 ] && padding=1

    echo -ne "${color}║${NC} $key"
    repeat_char " " $padding
    echo -e "$val ${color}║${NC}"
}

# ================= 结尾显示 =================
show_info() {
    echo ""
    print_box_top "${GREEN}"
    print_box_row "LotSpeed v$VERSION Installation Complete!" "center" "${GREEN}"
    print_box_row "ML-TCP Auto-Scaling Edition" "center" "${GREEN}"
    print_box_bottom "${GREEN}"

    echo ""

    # 调用新生成的脚本显示状态
    /usr/local/bin/lotspeed status

    echo ""
    print_box_top "${YELLOW}"
    print_box_row "Recommended Settings" "center" "${YELLOW}"
    print_box_div "${YELLOW}"
    print_kv_row "VPS/Cloud (<=1Gbps)" "lotspeed preset conservative" "${YELLOW}"
    print_kv_row "VPS/Cloud (>1Gbps)" "lotspeed preset balanced" "${YELLOW}"
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

    check_root || error_exit "Root check failed"
    check_system || error_exit "System check failed"
    detect_kernel_build_toolchain

    if [[ "$ACTION" == "-u" ]]; then
        echo -e "${CYAN}Starting dependency removal at $CURRENT_TIME${NC}"
        echo ""
        uninstall_dependencies || error_exit "Dependency removal failed"
        exit 0
    fi

    echo -e "${CYAN}Starting installation at $CURRENT_TIME${NC}"
    echo ""

    install_dependencies || error_exit "Dependency installation failed"
    download_source || error_exit "Source download failed"
    compile_module || error_exit "Module compilation failed"
    load_module || error_exit "Module loading failed"
    create_management_script || error_exit "Script creation failed"

    show_info

    echo "[$(date '+%Y-%m-%d %H:%M:%S')] LotSpeed v$VERSION installed by $CURRENT_USER" >> /var/log/lotspeed_install.log
}

main