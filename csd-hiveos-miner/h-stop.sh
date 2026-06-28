#!/bin/bash
# HiveOS stop script for CSD Pool Miner
# Cleanly stops all mining instances

cd "$(dirname "$0")"

echo "Stopping CSD Pool Miner..."

# Send SIGTERM first (graceful shutdown)
if pgrep -f "csd-pool-miner-linux-nvidia" > /dev/null 2>&1; then
    pkill -TERM -f "csd-pool-miner-linux-nvidia"
    
    # Wait up to 5 seconds for graceful exit
    for i in $(seq 1 5); do
        if ! pgrep -f "csd-pool-miner-linux-nvidia" > /dev/null 2>&1; then
            echo "CSD Pool Miner stopped gracefully"
            exit 0
        fi
        sleep 1
    done
    
    # Force kill if still running
    pkill -9 -f "csd-pool-miner-linux-nvidia" 2>/dev/null
    echo "CSD Pool Miner force-killed"
else
    echo "CSD Pool Miner was not running"
fi
