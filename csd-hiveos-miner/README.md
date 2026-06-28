# CSD Pool Miner - HiveOS Custom Miner

Custom miner package for mining **Compute Substrate (CSD)** on HiveOS.

## Supported Hardware

- **NVIDIA GPUs** (CUDA) — any card with recent drivers (GTX 1060+, RTX 2000/3000/4000/5000, CMP, Tesla, etc.)
- **CPU fallback** — runs on CPU if no GPU detected (SHA-NI hardware acceleration)
- Auto-detects GPU count and launches one instance per card

## Features

- Multi-GPU: automatically detects and uses all available NVIDIA GPUs
- Auto-tune: benchmarks CUDA geometry at startup for optimal performance
- Power management: `--power-limit` to cap wattage (requires root/elevated)
- Thermal safety: `--temp-limit` / `--temp-resume` to pause on overheat
- HiveOS stats: full integration (hashrate, temps, fans, accepted/rejected shares)
- GPU watchdog: auto-recovery on hung GPU

## Installation on HiveOS

### Flight Sheet Setup

1. Go to **Flight Sheets** → **Add New Flight Sheet**
2. **Coin**: leave empty or type `CSD`
3. **Wallet**: your CSD addr20 address (0x-prefixed, 42 hex chars)
4. **Pool**: select `Configure in miner`
5. **Miner**: select **Custom** → click **Setup Miner Config**

### Custom Miner Config

| Field | Value |
|-------|-------|
| **Miner name** | `csd-pool-miner` |
| **Installation URL** | `https://github.com/amavaljoh04-lang/csd-hiveos-miner/releases/download/v0.1.16/csd-pool-miner-v0.1.16-hiveos.tar.gz` |
| **Hash algorithm** | `sha256d` |
| **Wallet and worker template** | `%WAL%` |
| **Pool URL** | _(leave empty — pool is built-in)_ |
| **Extra config arguments** | see below |

### Recommended Extra Config Arguments

```
--power-limit 220 --temp-limit 80 --temp-resume 72
```

| Argument | Description | Default |
|----------|-------------|---------|
| `--power-limit <W>` | GPU board power cap in Watts (needs root) | card default |
| `--temp-limit <°C>` | Pause GPU if temperature exceeds this | disabled |
| `--temp-resume <°C>` | Resume GPU once it cools to this | limit - 5 |
| `--blocks <N>` | CUDA blocks per kernel launch | 560 |
| `--threads-per-block <N>` | CUDA threads per block | 256 |
| `--nonces-per-thread <N>` | Nonces per thread per launch | 4096 |
| `--backend <TYPE>` | Force backend: `cuda`, `opencl`, or `cpu` | auto |
| `--no-gpu-watchdog` | Disable hung-GPU watchdog | enabled |
| `--cpu-threads <N>` | Dual mining: CPU threads alongside GPU (0=off) | 0 in HiveOS |

### Examples

**Basic (auto settings):**
```
(leave extra config empty)
```

**Power-limited + thermal protection:**
```
--power-limit 200 --temp-limit 75 --temp-resume 68
```

**Maximum performance (no limits):**
```
--power-limit 350
```

## How it works

- The miner connects to the built-in CSD pool (no pool URL needed)
- One process per GPU, each on its own stats port (4000, 4001, 4002, ...)
- Shares are credited to your `--address` (wallet from flight sheet)
- The pool uses Stratum with VarDiff

## Creating a CSD Wallet

Option 1 — From the miner binary:
```bash
./csd-pool-miner-linux-nvidia newwallet
```

Option 2 — Browser extension:
Install [Cairn Wallet](https://chromewebstore.google.com/detail/cairn-wallet/nnjiejlalkcfckfojhihbbcpfhimfemd)

## Version

- Miner binary: `csd-pool-miner v0.1.16`
- HiveOS package: `v0.1.16`
- Algorithm: SHA-256d (double SHA-256)
- Backend: CUDA (NVIDIA), CPU fallback
