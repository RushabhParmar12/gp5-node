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
chmod +x gp5.sh tools/compare.sh   # make the scripts executable
./gp5.sh setup          # checks requirements, creates config.env, downloads GP5
nano config.env         # set NODE_NAME to something identifiable, e.g. alice-test
./gp5.sh start
./gp5.sh status
```

Your node appears on https://stats.xdcindia.com under its `NODE_NAME` within a few minutes.

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
| `./gp5.sh account create` | Create the node's coinbase address and password file |
| `./gp5.sh account show` | Show the address in `0x` and `xdc` format |
| `./gp5.sh account backup` | Save keystore + password to `backups/` |
| `./gp5.sh validator on\|off` | Sign blocks when elected (restarts the node) |
| `./gp5.sh speed [secs]` | Measure sync speed in blocks/s |
| `./gp5.sh crashtest` | Hard-kill the node and check where it resumes |
| `./gp5.sh compare [N]` | Compare N random blocks and receipts with the public RPC |
| `./gp5.sh setup --force` | Re-download the binary (after changing `GETH_VERSION`) |
| `./gp5.sh reset` | Delete chain data and resync from scratch |

Add `-y` to skip confirmation prompts.

## Running a masternode

Every node needs its own coinbase address. These commands create it, run the node as a validator, and keep the key safe.

```bash
./gp5.sh account create     # creates the address + data/.password, saves COINBASE in config.env
./gp5.sh account backup     # saves keystore + password to backups/ - copy it off the server
```

1. Wait until `./gp5.sh status` shows **Sync: synced**.
2. Propose the `xdc...` address from `account create` on the masternode page (Apothem: 10,000,000 TXDC stake).
3. Turn on validator mode (restarts the node):

```bash
./gp5.sh validator on
./gp5.sh status             # Validator line: ACTIVE masternode, or standby/candidate
```

A new candidate starts on standby. It's promoted automatically when it ranks among the active masternodes, checked every epoch (900 blocks). While the node is a validator, RPC must stay on `127.0.0.1`. The script refuses to start otherwise, because the key is unlocked.

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
| `ETHSTATS` | stats.xdcindia.com | `<secret>@<host>:<port>`, node name is added automatically; empty disables stats |
| `VALIDATOR` | `false` | Set by `./gp5.sh validator on` |
| `COINBASE` | empty | Set by `./gp5.sh account create` |
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

## Known issues

- **Reset to genesis with `STATE_SCHEME=hash`:** after an unclean shutdown (crash, `docker kill`, OOM, power loss) during fast sync, the node can rewind past the 90k-block limit and restart from block 0. Use `path` (the default here) and always stop with `./gp5.sh stop`.
- **`downloaded geth will not run on this platform`** from the official installer on Ubuntu 22.04 is the glibc 2.38 requirement. This script avoids it by using a container.

## Troubleshooting

| Error | Fix |
|---|---|
| `Permission denied` running `./gp5.sh` | `chmod +x gp5.sh tools/compare.sh` (or run `bash gp5.sh ...`) |
| `$'\r': command not found` | Windows line endings: `sed -i 's/\r$//' gp5.sh tools/compare.sh config.env.example` |
| `container name "/gp5-apothem" is already in use` | `docker rm -f gp5-apothem`, then `./gp5.sh start` |
| `sha256 mismatch` | The download is corrupted or the binary changed; re-run `./gp5.sh setup --force` or update `GETH_SHA256` |

## Reporting a bug

Include the output of:

```bash
./gp5.sh status
./gp5.sh logs --errors
./gp5.sh logs --save        # attach the saved file
grep -v '^#' config.env | grep -v '^$'   # remove any secrets first
```
