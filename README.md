# GP5 Node Tester

Run and test **GP5**, XDC Network's modern geth client (go-ethereum 1.14+ with XDPoS), on Apothem or mainnet with a single script.

GP5 binaries need **glibc 2.38+**. Many servers (e.g. Ubuntu 22.04) ship an older glibc, so this script runs the official binary inside an `ubuntu:24.04` container. The binary and all chain data stay in this folder; the container only provides the system libraries.

## Requirements

- Linux, x86_64 (amd64)
- Docker, curl, jq (`setup` offers to install any that are missing on Debian/Ubuntu)
- Disk: ~50 GB+ for Apothem, much more for mainnet
- Port `30303` (TCP + UDP) open for peers

## Quick start

```bash
git clone <this-repo-url> gp5-node
cd gp5-node
./gp5.sh setup          # checks requirements, creates config.env, downloads GP5
nano config.env         # set NODE_NAME to something identifiable, e.g. alice-test
./gp5.sh start
./gp5.sh status
```

Open the P2P port if you use ufw:

```bash
sudo ufw allow 30303/tcp && sudo ufw allow 30303/udp
```

## Commands

| Command | What it does |
|---|---|
| `./gp5.sh setup` | Check requirements, create `config.env`, download and test the binary |
| `./gp5.sh start` | Start the node |
| `./gp5.sh stop` | Stop cleanly (gives geth time to save state) |
| `./gp5.sh restart` | Clean stop + start |
| `./gp5.sh status` | Client version, chain ID, block, peers, sync %, disk |
| `./gp5.sh logs [N]` | Follow the live log |
| `./gp5.sh logs --errors` | Recent warnings and errors |
| `./gp5.sh logs --save` | Save the full log to `logs/` for bug reports |
| `./gp5.sh attach` | Open the geth console over RPC |
| `./gp5.sh attach "eth.blockNumber"` | Run one console command |
| `./gp5.sh rpc eth_blockNumber` | Raw JSON-RPC call |
| `./gp5.sh speed [secs]` | Measure sync speed in blocks/s |
| `./gp5.sh crashtest` | Hard-kill the node and check where it resumes |
| `./gp5.sh compare [N]` | Compare N random blocks and receipts with the public RPC |
| `./gp5.sh setup --force` | Re-download the binary (after changing `GETH_VERSION`) |
| `./gp5.sh reset` | Delete chain data and resync from scratch |

Add `-y` to skip confirmation prompts.

## Configuration

All settings live in `config.env` (created from `config.env.example`). The main ones:

| Setting | Default | Notes |
|---|---|---|
| `NODE_NAME` | `my-gp5-node` | Shown to peers and on stats dashboards. Please change it. |
| `NETWORK` | `apothem` | `apothem` (chain ID 51) or `mainnet` (chain ID 50) |
| `GETH_VERSION` | `v1.17.10-xdc.26` | Binary to download |
| `GETH_SHA256` | empty | Pin the binary hash to verify downloads |
| `SYNC_MODE` | `full` | `full` or `snap` |
| `STATE_SCHEME` | `path` | `path` recovers from crashes; `hash` can lose a lot of progress after an unclean shutdown |
| `RPC_ADDR` | `127.0.0.1` | Keep local; use an SSH tunnel for remote access |
| `ETHSTATS` | empty | `<secret>@<host>:<port>`, node name is added automatically |
| `STOP_TIMEOUT` | `300` | Seconds geth gets to save state on stop/restart |

## Folder layout

```
gp5-node/
├── gp5.sh               main script
├── config.env.example   template (committed)
├── config.env           your settings (not committed)
├── tools/compare.sh     block/receipt comparison against the public RPC
├── bin/geth             downloaded binary (not committed)
├── data/                chain data (not committed)
└── logs/                saved logs and test results (not committed)
```

## Connecting to RPC from your laptop

RPC only listens on `127.0.0.1` by default. Use an SSH tunnel:

```bash
ssh -N -L 8545:127.0.0.1:8545 user@your-server
```

Then use `http://localhost:8545` (chain ID 51 for Apothem) in curl, scripts or MetaMask.
