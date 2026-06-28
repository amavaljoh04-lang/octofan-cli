#!/bin/bash
# HiveOS stats script for CSD Pool Miner
# Returns hashrate, temps, and fan data in HiveOS JSON format
# Compatible with any number of GPUs

cd "$(dirname "$0")"
. h-manifest.conf

MINER_BIN="./csd-pool-miner-linux-nvidia"

# Try the built-in hiveos-stats command first (cleanest method)
STATS_JSON=$($MINER_BIN hiveos-stats 2>/dev/null)
if [[ $? -eq 0 && ! -z "$STATS_JSON" && "$STATS_JSON" != *"error"* ]]; then
    echo "$STATS_JSON"
    exit 0
fi

# Fallback: build stats manually from per-GPU stats ports

# Detect number of running instances
PIDS=($(pgrep -f "csd-pool-miner-linux-nvidia" 2>/dev/null))
GPU_COUNT=${#PIDS[@]}

if [[ $GPU_COUNT -eq 0 ]]; then
    # Miner not running - return zero stats
    echo '{"hs":[],"hs_units":"khs","temp":[],"fan":[],"uptime":0,"ver":"'$MINER_VER'","algo":"sha256d","ar":[0,0]}'
    exit 0
fi

# Collect hashrates from each GPU's stats endpoint
HS_ARRAY=""
ACCEPTED=0
REJECTED=0

for ((i=0; i<GPU_COUNT; i++)); do
    STATS_PORT=$((4000 + i))
    RESPONSE=$(curl -s --max-time 2 "http://127.0.0.1:${STATS_PORT}/1/summary" 2>/dev/null)
    
    if [[ ! -z "$RESPONSE" && "$RESPONSE" == *"hashrate"* ]]; then
        # Parse hashrate (xmrig-compatible JSON -> kH/s)
        HS=$(echo "$RESPONSE" | python3 -c "
import sys, json
try:
    data = json.load(sys.stdin)
    hr = data.get('hashrate', {}).get('total', [0])
    if isinstance(hr, list) and len(hr) > 0:
        print(int(hr[0] / 1000))
    else:
        print(0)
except:
    print(0)
" 2>/dev/null)
        [[ -z "$HS" || "$HS" == "" ]] && HS=0

        # Parse accepted/rejected
        AR=$(echo "$RESPONSE" | python3 -c "
import sys, json
try:
    data = json.load(sys.stdin)
    results = data.get('results', {})
    print(results.get('shares_good', 0), results.get('shares_total', 0) - results.get('shares_good', 0))
except:
    print('0 0')
" 2>/dev/null)
        A=$(echo $AR | awk '{print $1}')
        R=$(echo $AR | awk '{print $2}')
        ACCEPTED=$((ACCEPTED + A))
        REJECTED=$((REJECTED + R))
    else
        HS=0
    fi
    
    [[ ! -z "$HS_ARRAY" ]] && HS_ARRAY="${HS_ARRAY},"
    HS_ARRAY="${HS_ARRAY}${HS}"
done

# Get GPU temperatures and fan speeds via nvidia-smi
TEMP_ARRAY=""
FAN_ARRAY=""

if command -v nvidia-smi &>/dev/null; then
    while IFS= read -r temp; do
        [[ ! -z "$TEMP_ARRAY" ]] && TEMP_ARRAY="${TEMP_ARRAY},"
        TEMP_ARRAY="${TEMP_ARRAY}${temp}"
    done < <(nvidia-smi --query-gpu=temperature.gpu --format=csv,noheader,nounits 2>/dev/null)
    
    while IFS= read -r fan; do
        [[ ! -z "$FAN_ARRAY" ]] && FAN_ARRAY="${FAN_ARRAY},"
        FAN_ARRAY="${FAN_ARRAY}${fan}"
    done < <(nvidia-smi --query-gpu=fan.speed --format=csv,noheader,nounits 2>/dev/null)
fi

# Calculate uptime from oldest miner process
OLDEST_PID=${PIDS[0]}
if [[ -f "/proc/${OLDEST_PID}/stat" ]]; then
    START_TIME=$(stat -c %Y /proc/${OLDEST_PID} 2>/dev/null || echo $(date +%s))
    UPTIME=$(( $(date +%s) - START_TIME ))
else
    UPTIME=0
fi

# Output HiveOS-compatible JSON
cat <<EOF
{"hs":[$HS_ARRAY],"hs_units":"khs","temp":[$TEMP_ARRAY],"fan":[$FAN_ARRAY],"uptime":$UPTIME,"ver":"$MINER_VER","algo":"sha256d","ar":[$ACCEPTED,$REJECTED]}
EOF
