#!/bin/bash
#
# 数据分析脚本
#
# 用法: ./analyze.sh
#

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# 检查虚拟环境
if [ ! -d "${SCRIPT_DIR}/venv" ]; then
    echo "错误: 虚拟环境不存在"
    echo "请先运行: ./setup.sh"
    exit 1
fi

# 激活虚拟环境
source "${SCRIPT_DIR}/venv/bin/activate"

# 检查数据目录
if [ ! -d "${SCRIPT_DIR}/mdp_data" ] || [ -z "$(ls -A ${SCRIPT_DIR}/mdp_data/*.csv 2>/dev/null)" ]; then
    echo "错误: 没有找到数据文件"
    echo "请先运行: ./collect.sh"
    exit 1
fi

echo "=========================================="
echo "LotMonitor 数据分析"
echo "=========================================="
echo ""

# 运行分析
python3 "${SCRIPT_DIR}/mdp_collector.py" analyze
