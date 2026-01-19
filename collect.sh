#!/bin/bash
#
# 数据采集脚本
#
# 用法: ./collect.sh [时长秒数]
#
# 示例:
#   ./collect.sh        # 默认采集 60 秒
#   ./collect.sh 300    # 采集 5 分钟
#   ./collect.sh 3600   # 采集 1 小时
#

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DURATION=${1:-60}

# 检查虚拟环境
if [ ! -d "${SCRIPT_DIR}/venv" ]; then
    echo "错误: 虚拟环境不存在"
    echo "请先运行: ./setup.sh"
    exit 1
fi

# 激活虚拟环境
source "${SCRIPT_DIR}/venv/bin/activate"

# 检查模块是否加载
if [ ! -f /proc/lotmonitor/stats ]; then
    echo "警告: lotmonitor 模块未加载"
    echo ""
    echo "请先加载模块:"
    echo "  sudo insmod lotmonitor.ko"
    echo ""
    read -p "是否继续? (y/n) " -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        exit 1
    fi
fi

echo "=========================================="
echo "LotMonitor 数据采集"
echo "=========================================="
echo "采集时长: ${DURATION} 秒"
echo ""

# 运行采集
python3 "${SCRIPT_DIR}/mdp_collector.py" collect --duration "${DURATION}"

echo ""
echo "采集完成! 数据保存在 mdp_data/ 目录"
