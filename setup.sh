#!/bin/bash
#
# LotMonitor 环境设置脚本
#
# 用法: ./setup.sh
#

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VENV_DIR="${SCRIPT_DIR}/venv"

echo "=========================================="
echo "LotMonitor 环境设置"
echo "=========================================="

# 检查 Python3
if ! command -v python3 &> /dev/null; then
    echo "错误: 未找到 python3"
    echo "请安装 Python 3.8+"
    exit 1
fi

PYTHON_VERSION=$(python3 -c 'import sys; print(f"{sys.version_info.major}.{sys.version_info.minor}")')
echo "Python 版本: ${PYTHON_VERSION}"

# 创建虚拟环境
if [ ! -d "${VENV_DIR}" ]; then
    echo ""
    echo "创建虚拟环境..."
    python3 -m venv "${VENV_DIR}"
    echo "虚拟环境已创建: ${VENV_DIR}"
else
    echo "虚拟环境已存在: ${VENV_DIR}"
fi

# 激活虚拟环境
source "${VENV_DIR}/bin/activate"

# 升级 pip
echo ""
echo "升级 pip..."
pip install --upgrade pip -q

# 安装依赖
echo ""
echo "安装依赖..."
pip install -r "${SCRIPT_DIR}/requirements.txt" -q

echo ""
echo "=========================================="
echo "设置完成!"
echo "=========================================="
echo ""
echo "使用方法:"
echo ""
echo "  # 激活环境"
echo "  source venv/bin/activate"
echo ""
echo "  # 采集数据 (60秒)"
echo "  ./collect.sh 60"
echo ""
echo "  # 分析数据"
echo "  ./analyze.sh"
echo ""
echo "  # 训练模型"
echo "  ./train.sh 100"
echo ""
echo "  # 查看模块状态"
echo "  ./status.sh"
echo ""
