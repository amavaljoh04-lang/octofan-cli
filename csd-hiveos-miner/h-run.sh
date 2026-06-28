#!/bin/bash
# HiveOS run script for CSD Pool Miner
# Launches one miner instance per GPU (auto-detects GPU count)
# Compatible with any NVIDIA GPU (CUDA) or fallback to CPU

cd "$(dirname "$0")"
[[ -e /hive-config/wallet.conf ]] && . /hive-config/wallet.conf
. h-manifest.conf

MINER_BIN="./csd-pool-miner-linux-nvidia"

# Create log directory
mkdir -p /var/log/miner/csd-pool-miner 2>/dev/null

# Wallet address from flight sheet (CUSTOM_TEMPLATE = %WAL%)
WALLET_ADDR="$CUSTOM_TEMPLATE"
[[ -z "$WALLET_ADDR" ]] && echo "ERROR: No wallet address set in flight sheet" && exit 1

# Parse extra config from flight sheet
EXTRA_ARGS=""
[[ ! -z "$CUSTOM_USER_CONFIG" ]] && EXTRA_ARGS="$CUSTOM_USER_CONFIG"

# Detect backend: check for NVIDIA GPUs first
GPU_COUNT=0
BACKEND="cpu"

if command -v nvidia-smi &>/dev/null; then
    GPU_COUNT=$(nvidia-smi -L 2>/dev/null | wc -l)
    if [[ $GPU_COUNT -gt 0 ]]; then
        BACKEND="cuda"
    fi
fi

# If no NVIDIA GPU, try OpenCL
if [[ "$BACKEND" == "cpu" ]] && [[ "$EXTRA_ARGS" == *"--backend opencl"* ]]; then
    BACKEND="opencl"
    # Attempt GPU count from OpenCL
    GPU_COUNT=$($MINER_BIN devices 2>/dev/null | grep -c "Device" || echo 1)
fi

# Fallback to CPU if no GPUs
if [[ $GPU_COUNT -eq 0 ]]; then
    echo "No GPUs detected, running in CPU-only mode"
    echo "Starting CSD Pool Miner v${MINER_VER} (CPU backend)"
    echo "Wallet: ${WALLET_ADDR}"
    $MINER_BIN \
        --address "$WALLET_ADDR" \
        --backend cpu \
        $EXTRA_ARGS \
        2>&1 | tee --append ${CUSTOM_LOG_BASENAME}.log
    exit $?
fi

echo "========================================"
echo " CSD Pool Miner v${MINER_VER} - HiveOS"
echo " Backend: ${BACKEND}"
echo " GPUs detected: ${GPU_COUNT}"
echo " Wallet: ${WALLET_ADDR}"
echo " Extra args: ${EXTRA_ARGS}"
echo "========================================"

# Kill any existing instances
pkill -f "csd-pool-miner-linux-nvidia" 2>/dev/null
sleep 1

# Launch one instance per GPU
for ((i=0; i<GPU_COUNT; i++)); do
    STATS_PORT=$((4000 + i))
    echo "[GPU $i] Launching (stats: http://127.0.0.1:${STATS_PORT}/1/summary)"
    $MINER_BIN \
        --address "$WALLET_ADDR" \
        --backend $BACKEND \
        --device $i \
        --cpu-threads 0 \
        --stats-port $STATS_PORT \
        --auto-tune \
        $EXTRA_ARGS \
        >> ${CUSTOM_LOG_BASENAME}_gpu${i}.log 2>&1 &
    sleep 2
done

echo "[OK] All $GPU_COUNT GPU miners launched"
echo ""

# Follow the first GPU log to keep HiveOS happy (it expects foreground output)
tail -f ${CUSTOM_LOG_BASENAME}_gpu0.log 2>/dev/null
