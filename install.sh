#!/bin/bash
#
# LotSpeed v2.0 + NeoQ v3.0 - Complete Network Optimization Suite
# Author: uk0 @ 2025
# GitHub: https://github.com/uk0/lotspeed
#
# Usage:
#   curl -fsSL https://raw.githubusercontent.com/uk0/lotspeed/merge_bl/install.sh | sudo bash
#   Or run locally: sudo bash install.sh
#

set -e

# ================= 配置区域 =================
GITHUB_REPO="uk0/lotspeed"
GITHUB_BRANCH="merge_bl"
INSTALL_DIR="/opt/lotspeed"
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
BOLD='\033[1m'
NC='\033[0m'

# ================= UI 核心算法 =================
BOX_WIDTH=70

get_width() {
    local str="$1"
    local clean_str=$(echo -e "$str" | sed -r "s/\x1B\[([0-9]{1,2}(;[0-9]{1,2})?)?[mGK]//g" 2>/dev/null || echo "$str")
    echo ${#clean_str}
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
    cat << 'BANNER'
╔══════════════════════════════════════════════════════════════════════╗
║                                                                      ║
║      _          _   ____                      _                      ║
║     | |    ___ | |_/ ___| _ __   ___  ___  __| |                     ║
║     | |   / _ \| __\___ \| '_ \ / _ \/ _ \/ _` |                     ║
║     | |__| (_) | |_ ___) | |_) |  __/  __/ (_| |                     ║
║     |_____\___/ \__|____/| .__/ \___|\___|\___|                      ║
║                          |_|                                         ║
║                                                                      ║
║        LotSpeed v2.0 + NeoQ v3.0 Network Optimization Suite          ║
║                                                                      ║
╚══════════════════════════════════════════════════════════════════════╝
BANNER
    echo -e "${NC}"
}

# ================= 系统检查函数 =================

check_root() {
    if [[ $EUID -ne 0 ]]; then
        log_error "This script must be run as root"
        echo -e "${YELLOW}Try: sudo bash $0${NC}"
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

    if [[ $KERNEL_MAJOR -lt 5 ]]; then
        log_error "Kernel version must be >= 5.0 (current: $(uname -r))"
        exit 1
    fi

    ARCH=$(uname -m)
    log_success "System: $OS $OS_VERSION (kernel $(uname -r), $ARCH)"
}

install_dependencies() {
    log_info "Installing dependencies..."

    if [[ "$OS" == "centos" ]]; then
        yum install -y gcc make kernel-devel-$(uname -r) kernel-headers-$(uname -r) wget curl bc iproute-tc 2>/dev/null || {
            yum install -y gcc make kernel-devel kernel-headers wget curl bc iproute-tc
        }
    elif [[ "$OS" == "debian" ]] || [[ "$OS" == "ubuntu" ]]; then
        apt-get update >/dev/null 2>&1
        apt-get install -y gcc make linux-headers-$(uname -r) wget curl bc iproute2 2>/dev/null || {
            apt-get install -y gcc make linux-headers-generic wget curl bc iproute2
        }
    fi

    log_success "Dependencies installed"
}

# ================= 下载源码 =================

download_source() {
    log_info "Downloading source code..."

    mkdir -p $INSTALL_DIR
    cd $INSTALL_DIR

    # 下载 LotSpeed 源码
    curl -fsSL "https://raw.githubusercontent.com/$GITHUB_REPO/$GITHUB_BRANCH/lotspeed.c" -o lotspeed.c || {
        log_error "Failed to download lotspeed.c"
        exit 1
    }

    # 下载 NeoQ 源码
    curl -fsSL "https://raw.githubusercontent.com/$GITHUB_REPO/$GITHUB_BRANCH/qdisc_newneo.c" -o qdisc_newneo.c || {
        log_error "Failed to download qdisc_newneo.c"
        exit 1
    }

    # 创建 Makefile
    cat > Makefile << 'MAKEFILE'
KERNEL_RELEASE  ?= $(shell uname -r)
KERNEL_DIR      ?= /lib/modules/$(KERNEL_RELEASE)/build

obj-m += lotspeed.o
obj-m += sch_neoq.o
sch_neoq-objs := qdisc_newneo.o

ccflags-y := -std=gnu99 -DCONFIG_NET_SCH_DEFAULT

.PHONY: all clean install

all:
	$(MAKE) -C $(KERNEL_DIR) M=$(PWD) modules

clean:
	$(MAKE) -C $(KERNEL_DIR) M=$(PWD) clean

install: all
	cp lotspeed.ko /lib/modules/$(KERNEL_RELEASE)/kernel/net/ipv4/ 2>/dev/null || true
	cp sch_neoq.ko /lib/modules/$(KERNEL_RELEASE)/kernel/net/sched/ 2>/dev/null || true
	depmod -a
MAKEFILE

    log_success "Source code downloaded"
}

# ================= 编译模块 =================

compile_modules() {
    log_info "Compiling kernel modules..."

    cd $INSTALL_DIR
    make clean >/dev/null 2>&1 || true

    if ! make 2>&1; then
        log_error "Compilation failed"
        exit 1
    fi

    if [[ ! -f lotspeed.ko ]]; then
        log_error "lotspeed.ko not found"
        exit 1
    fi

    if [[ ! -f sch_neoq.ko ]]; then
        log_error "sch_neoq.ko not found"
        exit 1
    fi

    log_success "Modules compiled successfully"
}

# ================= 安装模块 =================

install_modules() {
    log_info "Installing kernel modules..."

    cd $INSTALL_DIR

    # 复制到系统目录
    mkdir -p /lib/modules/$(uname -r)/kernel/net/ipv4/
    mkdir -p /lib/modules/$(uname -r)/kernel/net/sched/
    cp lotspeed.ko /lib/modules/$(uname -r)/kernel/net/ipv4/
    cp sch_neoq.ko /lib/modules/$(uname -r)/kernel/net/sched/
    depmod -a

    log_success "Modules installed"
}

# ================= 获取默认拥塞控制算法 =================

get_default_cc() {
    local available=$(sysctl -n net.ipv4.tcp_available_congestion_control 2>/dev/null)
    if echo "$available" | grep -q "cubic"; then echo "cubic"
    elif echo "$available" | grep -q "reno"; then echo "reno"
    elif echo "$available" | grep -q "bbr"; then echo "bbr"
    else echo "cubic"
    fi
}

# ================= 安全卸载模块 =================

safe_unload_module() {
    local module="$1"
    local algo_name="$2"

    print_box_top "${YELLOW}"
    print_box_row "Safe Unload: $module" "center" "${YELLOW}"
    print_box_div "${YELLOW}"

    # 1. 切换到默认算法
    local default_cc=$(get_default_cc)
    print_box_row "Switching to $default_cc..." "left" "${YELLOW}"
    sysctl -w net.ipv4.tcp_congestion_control=$default_cc >/dev/null 2>&1

    # 2. 等待连接迁移
    sleep 2

    # 3. 查找并关闭使用该算法的连接（排除SSH 22端口）
    if [[ -n "$algo_name" ]]; then
        print_box_row "Closing connections using $algo_name..." "left" "${YELLOW}"

        # 获取使用该算法的连接（排除22端口）
        local conns=$(ss -tnp 2>/dev/null | grep "$algo_name" | grep -v ":22 " | grep -v ":22$" || true)
        local count=0

        if [[ -n "$conns" ]]; then
            echo "$conns" | while read line; do
                # 提取本地地址和端口
                local local_addr=$(echo "$line" | awk '{print $4}')
                local remote_addr=$(echo "$line" | awk '{print $5}')

                # 使用ss -K关闭连接 (需要较新内核)
                ss -K dst $remote_addr 2>/dev/null || true
                ((count++)) || true
            done
            print_kv_row "Connections closed" "$count" "${YELLOW}"
        else
            print_box_row "No active connections to close" "left" "${YELLOW}"
        fi
    fi

    # 4. 等待一会让连接关闭
    sleep 1

    # 5. 尝试卸载模块
    print_box_row "Unloading module..." "left" "${YELLOW}"

    local retry=0
    while lsmod | grep -q "^${module} " && [ $retry -lt 5 ]; do
        rmmod $module 2>/dev/null && break
        ((retry++))
        print_box_row "Retry $retry/5..." "left" "${YELLOW}"
        sleep 2
    done

    # 6. 强制卸载
    if lsmod | grep -q "^${module} "; then
        print_box_row "Force unloading..." "left" "${YELLOW}"
        rmmod -f $module 2>/dev/null || {
            print_box_row "${RED}Failed to unload (reboot required)${NC}" "left" "${YELLOW}"
            print_box_bottom "${YELLOW}"
            return 1
        }
    fi

    print_box_row "${GREEN}Module unloaded successfully${NC}" "center" "${YELLOW}"
    print_box_bottom "${YELLOW}"
    return 0
}

# ================= 创建管理脚本 =================

create_management_script() {
    log_info "Creating management script..."

    cat > /usr/local/bin/lotspeed << 'SCRIPT_EOF'
#!/bin/bash
#
# LotSpeed + NeoQ Management Script
#

INSTALL_DIR="/opt/lotspeed"
CONFIG_FILE="/etc/lotspeed.conf"
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

BOX_WIDTH=70

get_width() {
    local str="$1"
    local clean_str=$(echo -e "$str" | sed -r "s/\x1B\[([0-9]{1,2}(;[0-9]{1,2})?)?[mGK]//g" 2>/dev/null || echo "$str")
    echo ${#clean_str}
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

get_default_cc() {
    local available=$(sysctl -n net.ipv4.tcp_available_congestion_control 2>/dev/null)
    if echo "$available" | grep -q "cubic"; then echo "cubic"
    elif echo "$available" | grep -q "reno"; then echo "reno"
    elif echo "$available" | grep -q "bbr"; then echo "bbr"
    else echo "cubic"
    fi
}

# 安全卸载模块
safe_unload() {
    local module="$1"
    local algo_name="$2"

    # 切换算法
    local default_cc=$(get_default_cc)
    echo -e "${YELLOW}Switching to $default_cc...${NC}"
    sysctl -w net.ipv4.tcp_congestion_control=$default_cc >/dev/null 2>&1
    sleep 2

    # 关闭连接（排除22端口）
    if [[ -n "$algo_name" ]]; then
        echo -e "${YELLOW}Closing $algo_name connections (except SSH)...${NC}"
        ss -tnp 2>/dev/null | grep "$algo_name" | grep -v ":22 " | grep -v ":22$" | while read line; do
            local remote=$(echo "$line" | awk '{print $5}')
            ss -K dst $remote 2>/dev/null || true
        done
    fi
    sleep 1

    # 卸载模块
    echo -e "${YELLOW}Unloading $module...${NC}"
    local retry=0
    while lsmod | grep -q "^${module} " && [ $retry -lt 5 ]; do
        rmmod $module 2>/dev/null && break
        ((retry++))
        echo -e "${YELLOW}Retry $retry/5...${NC}"
        sleep 2
    done

    if lsmod | grep -q "^${module} "; then
        rmmod -f $module 2>/dev/null || {
            echo -e "${RED}Failed to unload. Reboot may be required.${NC}"
            return 1
        }
    fi
    echo -e "${GREEN}Module unloaded.${NC}"
}

# 显示状态
show_status() {
    print_box_top
    print_box_row "LotSpeed + NeoQ Status" "center"
    print_box_div

    # 当前算法
    local current=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null)
    print_kv_row "Active CC Algorithm" "${CYAN}$current${NC}"

    # LotSpeed 模块
    if lsmod | grep -q "^lotspeed "; then
        print_kv_row "LotSpeed Module" "${GREEN}● Loaded${NC}"
        local ref=$(lsmod | grep "^lotspeed " | awk '{print $3}')
        print_kv_row "  Reference Count" "$ref"
    else
        print_kv_row "LotSpeed Module" "${RED}○ Not Loaded${NC}"
    fi

    # NeoQ 模块
    if lsmod | grep -q "^sch_neoq "; then
        print_kv_row "NeoQ Module" "${GREEN}● Loaded${NC}"
        local ref=$(lsmod | grep "^sch_neoq " | awk '{print $3}')
        print_kv_row "  Reference Count" "$ref"
    else
        print_kv_row "NeoQ Module" "${RED}○ Not Loaded${NC}"
    fi

    # NeoQ qdisc
    local neoq_qdisc=$(tc qdisc show 2>/dev/null | grep -c "neoq" || echo "0")
    if [[ "$neoq_qdisc" -gt 0 ]]; then
        print_kv_row "NeoQ Qdisc" "${GREEN}Active on $neoq_qdisc interface(s)${NC}"
    fi

    # sysctl 接口
    if [[ -d "$SYSCTL_PATH" ]]; then
        print_kv_row "LotSpeed sysctl" "${GREEN}Available${NC}"
    fi

    # /proc/net/neoq
    if [[ -f /proc/net/neoq ]]; then
        print_kv_row "NeoQ Stats" "${GREEN}/proc/net/neoq${NC}"
    fi

    print_box_bottom
}

# 交互式菜单
interactive_menu() {
    while true; do
        clear
        print_box_top "${MAGENTA}"
        print_box_row "LotSpeed + NeoQ Management" "center" "${MAGENTA}"
        print_box_div "${MAGENTA}"

        local current=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null)
        print_kv_row "Current Algorithm" "${CYAN}$current${NC}" "${MAGENTA}"
        print_box_div "${MAGENTA}"

        print_box_row "  ${BOLD}TCP Congestion Control${NC}" "left" "${MAGENTA}"
        print_kv_row "1)" "Enable LotSpeed (BBR v3 Hybrid)" "${MAGENTA}"
        print_kv_row "2)" "Disable LotSpeed (switch to default)" "${MAGENTA}"
        print_box_div "${MAGENTA}"

        print_box_row "  ${BOLD}Queue Discipline (NeoQ)${NC}" "left" "${MAGENTA}"
        print_kv_row "3)" "Enable NeoQ on interface" "${MAGENTA}"
        print_kv_row "4)" "Disable NeoQ on interface" "${MAGENTA}"
        print_kv_row "5)" "Show NeoQ statistics" "${MAGENTA}"
        print_box_div "${MAGENTA}"

        print_box_row "  ${BOLD}Module Management${NC}" "left" "${MAGENTA}"
        print_kv_row "6)" "Load all modules" "${MAGENTA}"
        print_kv_row "7)" "Unload all modules (safe)" "${MAGENTA}"
        print_box_div "${MAGENTA}"

        print_box_row "  ${BOLD}Other${NC}" "left" "${MAGENTA}"
        print_kv_row "8)" "Show status" "${MAGENTA}"
        print_kv_row "9)" "LotSpeed parameters" "${MAGENTA}"
        print_kv_row "0)" "Exit" "${MAGENTA}"
        print_box_bottom "${MAGENTA}"

        echo ""
        read -p "Select option [0-9]: " choice

        case $choice in
            1)
                echo ""
                if ! lsmod | grep -q "^lotspeed "; then
                    echo -e "${YELLOW}Loading LotSpeed module...${NC}"
                    modprobe lotspeed 2>/dev/null || insmod $INSTALL_DIR/lotspeed.ko
                    sleep 1
                fi
                sysctl -w net.ipv4.tcp_congestion_control=lotspeed
                echo -e "${GREEN}LotSpeed enabled!${NC}"
                read -p "Press Enter to continue..."
                ;;
            2)
                echo ""
                safe_unload "lotspeed" "lotspeed"
                read -p "Press Enter to continue..."
                ;;
            3)
                echo ""
                echo -e "${CYAN}Available interfaces:${NC}"
                ip -o link show | awk -F': ' '{print "  " $2}'
                echo ""
                read -p "Enter interface name (e.g., eth0): " iface
                if [[ -n "$iface" ]]; then
                    if ! lsmod | grep -q "^sch_neoq "; then
                        echo -e "${YELLOW}Loading NeoQ module...${NC}"
                        modprobe sch_neoq 2>/dev/null || insmod $INSTALL_DIR/sch_neoq.ko
                        sleep 1
                    fi
                    tc qdisc replace dev $iface root neoq
                    echo -e "${GREEN}NeoQ enabled on $iface${NC}"
                fi
                read -p "Press Enter to continue..."
                ;;
            4)
                echo ""
                echo -e "${CYAN}Interfaces with NeoQ:${NC}"
                tc qdisc show 2>/dev/null | grep neoq | awk '{print "  " $5}'
                echo ""
                read -p "Enter interface name: " iface
                if [[ -n "$iface" ]]; then
                    tc qdisc del dev $iface root 2>/dev/null
                    echo -e "${GREEN}NeoQ disabled on $iface${NC}"
                fi
                read -p "Press Enter to continue..."
                ;;
            5)
                echo ""
                if [[ -f /proc/net/neoq ]]; then
                    cat /proc/net/neoq
                else
                    echo -e "${RED}NeoQ not active${NC}"
                fi
                echo ""
                tc -s qdisc show 2>/dev/null | grep -A 20 neoq || true
                read -p "Press Enter to continue..."
                ;;
            6)
                echo ""
                echo -e "${YELLOW}Loading modules...${NC}"
                modprobe lotspeed 2>/dev/null || insmod $INSTALL_DIR/lotspeed.ko 2>/dev/null || true
                modprobe sch_neoq 2>/dev/null || insmod $INSTALL_DIR/sch_neoq.ko 2>/dev/null || true
                sleep 1
                echo -e "${GREEN}Modules loaded.${NC}"
                lsmod | grep -E "lotspeed|sch_neoq" || echo "No modules loaded"
                read -p "Press Enter to continue..."
                ;;
            7)
                echo ""
                # 先禁用 NeoQ qdisc
                echo -e "${YELLOW}Removing NeoQ qdiscs...${NC}"
                for iface in $(tc qdisc show 2>/dev/null | grep neoq | awk '{print $5}'); do
                    tc qdisc del dev $iface root 2>/dev/null || true
                done
                sleep 1

                # 卸载 NeoQ
                if lsmod | grep -q "^sch_neoq "; then
                    safe_unload "sch_neoq" ""
                fi

                # 卸载 LotSpeed
                if lsmod | grep -q "^lotspeed "; then
                    safe_unload "lotspeed" "lotspeed"
                fi
                read -p "Press Enter to continue..."
                ;;
            8)
                echo ""
                show_status
                read -p "Press Enter to continue..."
                ;;
            9)
                echo ""
                if [[ -d "$SYSCTL_PATH" ]]; then
                    print_box_top
                    print_box_row "LotSpeed Parameters" "center"
                    print_box_div
                    for f in $SYSCTL_PATH/*; do
                        if [[ -f "$f" ]]; then
                            local name=$(basename "$f")
                            local val=$(cat "$f" 2>/dev/null)
                            print_kv_row "$name" "$val"
                        fi
                    done
                    print_box_bottom
                else
                    echo -e "${RED}LotSpeed sysctl interface not available${NC}"
                fi
                read -p "Press Enter to continue..."
                ;;
            0|q|Q)
                echo -e "${GREEN}Goodbye!${NC}"
                exit 0
                ;;
            *)
                echo -e "${RED}Invalid option${NC}"
                sleep 1
                ;;
        esac
    done
}

# 快速命令
case "$1" in
    start)
        modprobe lotspeed 2>/dev/null || insmod $INSTALL_DIR/lotspeed.ko
        sleep 1
        sysctl -w net.ipv4.tcp_congestion_control=lotspeed >/dev/null
        echo -e "${GREEN}LotSpeed started${NC}"
        ;;
    stop)
        safe_unload "lotspeed" "lotspeed"
        ;;
    neoq-start)
        iface="${2:-eth0}"
        modprobe sch_neoq 2>/dev/null || insmod $INSTALL_DIR/sch_neoq.ko
        sleep 1
        tc qdisc replace dev $iface root neoq
        echo -e "${GREEN}NeoQ started on $iface${NC}"
        ;;
    neoq-stop)
        iface="${2:-eth0}"
        tc qdisc del dev $iface root 2>/dev/null
        echo -e "${GREEN}NeoQ stopped on $iface${NC}"
        ;;
    neoq-stats)
        cat /proc/net/neoq 2>/dev/null || echo "NeoQ not active"
        ;;
    status)
        show_status
        ;;
    menu|interactive|"")
        interactive_menu
        ;;
    uninstall)
        print_box_top "${RED}"
        print_box_row "Uninstalling LotSpeed + NeoQ" "center" "${RED}"
        print_box_div "${RED}"

        # 移除 NeoQ qdiscs
        for iface in $(tc qdisc show 2>/dev/null | grep neoq | awk '{print $5}'); do
            tc qdisc del dev $iface root 2>/dev/null || true
        done

        # 卸载模块
        safe_unload "sch_neoq" "" 2>/dev/null || true
        safe_unload "lotspeed" "lotspeed" 2>/dev/null || true

        # 清理文件
        rm -rf $INSTALL_DIR
        rm -f /etc/modules-load.d/lotspeed.conf
        rm -f /etc/modules-load.d/sch_neoq.conf
        rm -f /lib/modules/$(uname -r)/kernel/net/ipv4/lotspeed.ko
        rm -f /lib/modules/$(uname -r)/kernel/net/sched/sch_neoq.ko
        rm -f $CONFIG_FILE
        rm -f /etc/sysctl.d/99-lotspeed.conf
        rm -f /etc/systemd/system/lotspeed.service
        depmod -a
        sed -i '/net.ipv4.tcp_congestion_control=lotspeed/d' /etc/sysctl.conf 2>/dev/null || true

        print_kv_row "Status" "${GREEN}Uninstalled${NC}" "${RED}"
        print_box_bottom "${RED}"

        rm -f /usr/local/bin/lotspeed
        ;;
    help|--help|-h)
        print_box_top
        print_box_row "LotSpeed + NeoQ Commands" "center"
        print_box_div
        print_kv_row "lotspeed" "Interactive menu"
        print_kv_row "lotspeed start" "Enable LotSpeed CC"
        print_kv_row "lotspeed stop" "Disable LotSpeed CC"
        print_kv_row "lotspeed neoq-start [iface]" "Enable NeoQ qdisc"
        print_kv_row "lotspeed neoq-stop [iface]" "Disable NeoQ qdisc"
        print_kv_row "lotspeed neoq-stats" "Show NeoQ statistics"
        print_kv_row "lotspeed status" "Show all status"
        print_kv_row "lotspeed uninstall" "Remove everything"
        print_box_bottom
        ;;
    *)
        echo "Unknown command: $1"
        echo "Run 'lotspeed help' for usage"
        exit 1
        ;;
esac
SCRIPT_EOF

    chmod +x /usr/local/bin/lotspeed
    log_success "Management script created at /usr/local/bin/lotspeed"
}

# ================= 创建 systemd 服务 =================

create_systemd_service() {
    log_info "Creating systemd service..."

    cat > /etc/systemd/system/lotspeed.service << 'EOF'
[Unit]
Description=LotSpeed + NeoQ Network Optimization
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

    log_success "Systemd service created"
}

# ================= 显示安装完成信息 =================

show_completion() {
    echo ""
    print_box_top "${GREEN}"
    print_box_row "Installation Complete!" "center" "${GREEN}"
    print_box_row "LotSpeed v2.0 + NeoQ v3.0" "center" "${GREEN}"
    print_box_bottom "${GREEN}"

    echo ""
    print_box_top "${CYAN}"
    print_box_row "Quick Start" "center" "${CYAN}"
    print_box_div "${CYAN}"
    print_kv_row "Interactive Menu" "lotspeed" "${CYAN}"
    print_box_div "${CYAN}"
    print_kv_row "Enable LotSpeed" "lotspeed start" "${CYAN}"
    print_kv_row "Enable NeoQ" "lotspeed neoq-start eth0" "${CYAN}"
    print_kv_row "Show Status" "lotspeed status" "${CYAN}"
    print_kv_row "NeoQ Stats" "cat /proc/net/neoq" "${CYAN}"
    print_box_div "${CYAN}"
    print_box_row "Run 'lotspeed' for interactive menu" "center" "${CYAN}"
    print_box_bottom "${CYAN}"
    echo ""
}

# ================= 交互式安装菜单 =================

interactive_install() {
    clear
    print_banner

    print_box_top "${MAGENTA}"
    print_box_row "Installation Options" "center" "${MAGENTA}"
    print_box_div "${MAGENTA}"
    print_kv_row "1)" "Install LotSpeed + NeoQ (Full)" "${MAGENTA}"
    print_kv_row "2)" "Install LotSpeed only" "${MAGENTA}"
    print_kv_row "3)" "Install NeoQ only" "${MAGENTA}"
    print_kv_row "4)" "Uninstall everything" "${MAGENTA}"
    print_kv_row "5)" "Check system status" "${MAGENTA}"
    print_kv_row "0)" "Exit" "${MAGENTA}"
    print_box_bottom "${MAGENTA}"

    echo ""
    read -p "Select option [0-5]: " choice

    case $choice in
        1)
            echo ""
            check_root
            check_system
            install_dependencies
            download_source
            compile_modules
            install_modules
            create_management_script
            create_systemd_service

            # 加载模块
            log_info "Loading modules..."
            insmod $INSTALL_DIR/lotspeed.ko 2>/dev/null || true
            insmod $INSTALL_DIR/sch_neoq.ko 2>/dev/null || true

            show_completion
            ;;
        2)
            echo ""
            check_root
            check_system
            install_dependencies

            mkdir -p $INSTALL_DIR
            cd $INSTALL_DIR
            curl -fsSL "https://raw.githubusercontent.com/$GITHUB_REPO/$GITHUB_BRANCH/lotspeed.c" -o lotspeed.c

            cat > Makefile << 'MF'
obj-m += lotspeed.o
KERNELDIR ?= /lib/modules/$(shell uname -r)/build
all:
	$(MAKE) -C $(KERNELDIR) M=$(PWD) modules
clean:
	$(MAKE) -C $(KERNELDIR) M=$(PWD) clean
MF
            make
            cp lotspeed.ko /lib/modules/$(uname -r)/kernel/net/ipv4/
            depmod -a
            insmod lotspeed.ko
            sysctl -w net.ipv4.tcp_congestion_control=lotspeed

            create_management_script
            log_success "LotSpeed installed and enabled!"
            ;;
        3)
            echo ""
            check_root
            check_system
            install_dependencies

            mkdir -p $INSTALL_DIR
            cd $INSTALL_DIR
            curl -fsSL "https://raw.githubusercontent.com/$GITHUB_REPO/$GITHUB_BRANCH/qdisc_newneo.c" -o qdisc_newneo.c

            cat > Makefile << 'MF'
obj-m += sch_neoq.o
sch_neoq-objs := qdisc_newneo.o
KERNELDIR ?= /lib/modules/$(shell uname -r)/build
ccflags-y := -std=gnu99
all:
	$(MAKE) -C $(KERNELDIR) M=$(PWD) modules
clean:
	$(MAKE) -C $(KERNELDIR) M=$(PWD) clean
MF
            make
            cp sch_neoq.ko /lib/modules/$(uname -r)/kernel/net/sched/
            depmod -a
            insmod sch_neoq.ko

            create_management_script
            log_success "NeoQ installed!"
            echo -e "${CYAN}Enable with: tc qdisc add dev eth0 root neoq${NC}"
            ;;
        4)
            echo ""
            check_root
            /usr/local/bin/lotspeed uninstall 2>/dev/null || {
                # 手动卸载
                for iface in $(tc qdisc show 2>/dev/null | grep neoq | awk '{print $5}'); do
                    tc qdisc del dev $iface root 2>/dev/null || true
                done
                local default_cc=$(get_default_cc)
                sysctl -w net.ipv4.tcp_congestion_control=$default_cc >/dev/null 2>&1
                rmmod sch_neoq 2>/dev/null || true
                rmmod lotspeed 2>/dev/null || true
                rm -rf $INSTALL_DIR
                rm -f /usr/local/bin/lotspeed
                rm -f /etc/systemd/system/lotspeed.service
                systemctl daemon-reload 2>/dev/null || true
            }
            log_success "Uninstalled!"
            ;;
        5)
            echo ""
            /usr/local/bin/lotspeed status 2>/dev/null || {
                echo -e "${CYAN}System Information:${NC}"
                echo "  Kernel: $(uname -r)"
                echo "  CC: $(sysctl -n net.ipv4.tcp_congestion_control)"
                echo "  Available: $(sysctl -n net.ipv4.tcp_available_congestion_control)"
                lsmod | grep -E "lotspeed|sch_neoq" && echo "" || echo "  No optimization modules loaded"
            }
            ;;
        0)
            echo -e "${GREEN}Goodbye!${NC}"
            exit 0
            ;;
        *)
            log_error "Invalid option"
            exit 1
            ;;
    esac
}

# ================= 主入口 =================

main() {
    # 如果有参数，直接安装
    if [[ "$1" == "--full" ]] || [[ "$1" == "-f" ]]; then
        clear
        print_banner
        check_root
        check_system
        install_dependencies
        download_source
        compile_modules
        install_modules
        create_management_script
        create_systemd_service
        insmod $INSTALL_DIR/lotspeed.ko 2>/dev/null || true
        insmod $INSTALL_DIR/sch_neoq.ko 2>/dev/null || true
        show_completion
    elif [[ "$1" == "--help" ]] || [[ "$1" == "-h" ]]; then
        echo "Usage: $0 [options]"
        echo ""
        echo "Options:"
        echo "  (no args)    Interactive installation menu"
        echo "  --full, -f   Full automatic installation"
        echo "  --help, -h   Show this help"
        exit 0
    else
        # 交互式安装
        interactive_install
    fi

    echo "[$(date '+%Y-%m-%d %H:%M:%S')] LotSpeed+NeoQ installed by $CURRENT_USER" >> /var/log/lotspeed_install.log 2>/dev/null || true
}

main "$@"
