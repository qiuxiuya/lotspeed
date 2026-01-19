#!/bin/bash
#
# LotMonitor Diagnostic Script
# Check module status and data quality
#

set -e

echo "=============================================="
echo "LotMonitor Diagnostic Report"
echo "=============================================="
echo ""

# Check if module is loaded
echo "--- Module Status ---"
if lsmod | grep -q lotmonitor; then
    echo "Module: LOADED"
    modinfo lotmonitor 2>/dev/null | grep -E "^(version|description):" || true
else
    echo "Module: NOT LOADED"
    echo "Run: sudo insmod lotmonitor.ko"
    exit 1
fi
echo ""

# Check /proc interface
echo "--- /proc Interface ---"
if [ -f /proc/lotmonitor/stats ]; then
    echo "/proc/lotmonitor/stats: OK"
    cat /proc/lotmonitor/stats
else
    echo "/proc/lotmonitor/stats: NOT FOUND"
fi
echo ""

# Check active connections
echo "--- Active Connections ---"
if [ -f /proc/lotmonitor/conns ]; then
    conn_count=$(wc -l < /proc/lotmonitor/conns)
    echo "Total connections: $((conn_count - 1))"  # Subtract header

    # Show connections with RTT > 0
    echo ""
    echo "Connections with valid RTT:"
    awk -F',' 'NR>1 && $5 > 0 {print $1":"$3" -> "$2":"$4" min_rtt="$5" curr_rtt="$6" pkts="$9}' /proc/lotmonitor/conns | head -10
else
    echo "/proc/lotmonitor/conns: NOT FOUND"
fi
echo ""

# Check samples
echo "--- Sample Buffer ---"
if [ -f /proc/lotmonitor/samples ]; then
    # Read samples to a temp file
    tmp_file=$(mktemp)
    cat /proc/lotmonitor/samples > "$tmp_file"

    total=$(wc -l < "$tmp_file")
    echo "Samples in buffer: $((total - 1))"

    if [ $total -gt 1 ]; then
        # Count valid samples (RTT > 0)
        valid=$(awk -F',' 'NR>1 && $7 > 0 {count++} END {print count+0}' "$tmp_file")
        echo "Valid samples (RTT>0): $valid"

        # Count samples with throughput
        tp=$(awk -F',' 'NR>1 && $18 > 0 {count++} END {print count+0}' "$tmp_file")
        echo "Samples with throughput: $tp"

        # Count samples with bytes_acked
        acked=$(awk -F',' 'NR>1 && $15 > 0 {count++} END {print count+0}' "$tmp_file")
        echo "Samples with bytes_acked: $acked"

        if [ $((total - 1)) -gt 0 ]; then
            valid_pct=$((valid * 100 / (total - 1)))
            echo ""
            echo "Data quality: ${valid_pct}% valid samples"

            if [ $valid_pct -lt 50 ]; then
                echo "WARNING: Low data quality detected!"
            else
                echo "OK: Data quality is acceptable"
            fi
        fi

        # Show some sample data
        echo ""
        echo "Recent samples with data:"
        awk -F',' 'NR>1 && ($7 > 0 || $14 > 0) {
            printf "%s:%s -> %s:%s rtt=%d bytes_acked=%d tp=%d\n",
                   $2, $4, $3, $5, $7, $15, $18
        }' "$tmp_file" | tail -5
    fi

    rm -f "$tmp_file"
else
    echo "/proc/lotmonitor/samples: NOT FOUND"
fi
echo ""

# Generate traffic for testing
echo "--- Quick Test ---"
echo "Generating test traffic (curl to httpbin.org)..."
curl -s -o /dev/null -w "HTTP %{http_code}, %{size_download} bytes, %{time_total}s\n" https://httpbin.org/get || echo "curl failed"
echo ""

# Wait and check again
sleep 1

echo "--- After Test Traffic ---"
if [ -f /proc/lotmonitor/samples ]; then
    tmp_file=$(mktemp)
    cat /proc/lotmonitor/samples > "$tmp_file"

    total=$(wc -l < "$tmp_file")
    valid=$(awk -F',' 'NR>1 && $7 > 0 {count++} END {print count+0}' "$tmp_file")

    echo "New samples: $((total - 1))"
    echo "Valid samples: $valid"

    rm -f "$tmp_file"
fi

echo ""
echo "=============================================="
echo "Diagnostic complete"
echo "=============================================="
