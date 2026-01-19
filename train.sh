#!/bin/bash
#
# MDP 模型训练脚本
#
# 用法: ./train.sh [训练轮数]
#
# 示例:
#   ./train.sh        # 默认训练 100 轮
#   ./train.sh 500    # 训练 500 轮
#   ./train.sh 1000   # 训练 1000 轮
#

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
EPOCHS=${1:-100}

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
    echo "错误: 没有找到训练数据"
    echo "请先运行: ./collect.sh"
    exit 1
fi

echo "=========================================="
echo "LotMonitor MDP 模型训练"
echo "=========================================="
echo "训练轮数: ${EPOCHS}"
echo ""

# 运行训练
python3 "${SCRIPT_DIR}/mdp_collector.py" train --epochs "${EPOCHS}"

echo ""
echo "训练完成!"
echo "模型保存在: mdp_data/q_model.npz"
