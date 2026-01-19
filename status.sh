#!/bin/bash
#
# 模块状态查看脚本
#
# 用法: ./status.sh
#

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo "=========================================="
echo "LotMonitor 状态"
echo "=========================================="
echo ""

# 检查模块是否加载
if [ -f /proc/lotmonitor/stats ]; then
    echo "模块状态: ✓ 已加载"
    echo ""
    echo "--- 统计信息 ---"
    cat /proc/lotmonitor/stats
    echo ""
    echo "--- 活跃连接 ---"
    CONN_COUNT=$(wc -l < /proc/lotmonitor/conns 2>/dev/null | tr -d ' ')
    CONN_COUNT=$((CONN_COUNT - 1))  # 减去头部行
    if [ "$CONN_COUNT" -gt 0 ]; then
        head -6 /proc/lotmonitor/conns
        if [ "$CONN_COUNT" -gt 5 ]; then
            echo "... 还有 $((CONN_COUNT - 5)) 个连接"
        fi
    else
        echo "(无活跃连接)"
    fi
else
    echo "模块状态: ✗ 未加载"
    echo ""
    echo "加载模块:"
    echo "  cd ${SCRIPT_DIR}"
    echo "  make"
    echo "  sudo insmod lotmonitor.ko"
fi

echo ""
echo "--- 数据文件 ---"
if [ -d "${SCRIPT_DIR}/mdp_data" ]; then
    DATA_COUNT=$(ls -1 ${SCRIPT_DIR}/mdp_data/*.csv 2>/dev/null | wc -l | tr -d ' ')
    if [ "$DATA_COUNT" -gt 0 ]; then
        echo "CSV 文件: ${DATA_COUNT} 个"
        ls -lh ${SCRIPT_DIR}/mdp_data/*.csv 2>/dev/null | tail -3
    else
        echo "CSV 文件: 无"
    fi

    if [ -f "${SCRIPT_DIR}/mdp_data/q_model.npz" ]; then
        echo ""
        echo "训练模型: ✓ 存在"
        ls -lh ${SCRIPT_DIR}/mdp_data/q_model.npz
    else
        echo ""
        echo "训练模型: 无"
    fi
else
    echo "数据目录: 不存在"
fi

echo ""
