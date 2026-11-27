#!/usr/bin/env bash
# gp5.sh - run and test an XDC GP5 (modern geth) node in Docker
# Run ./gp5.sh help for usage.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG="$ROOT/config.env"
BIN="$ROOT/bin/geth"
DATA="$ROOT/data"
LOGS="$ROOT/logs"

# ---------- output helpers ----------
if [ -t 1 ]; then G=$'\e[32m'; R=$'\e[31m'; Y=$'\e[33m'; B=$'\e[1m'; N=$'\e[0m'; else G='' R='' Y='' B='' N=''; fi
info() { echo "${B}==>${N} $*"; }
ok()   { echo "  ${G}OK${N}   $*"; }
warn() { echo "  ${Y}WARN${N} $*"; }
die()  { echo "  ${R}ERROR${N} $*" >&2; exit 1; }
confirm() { # confirm "question" -> returns 0 on yes; -y flag skips
  [ "${ASSUME_YES:-0}" = 1 ] && return 0
  read -r -p "$1 [y/N] " a; [[ "$a" =~ ^[Yy]$ ]]
}

# ---------- config ----------
load_config() {
  [ -f "$CONFIG" ] || die "config.env not found. Run: ./gp5.sh setup"
  # shellcheck disable=SC1090
  source "$CONFIG"
  : "${NODE_NAME:?set NODE_NAME in config.env}"
  NETWORK="${NETWORK:-apothem}"
  SYNC_MODE="${SYNC_MODE:-full}"; STATE_SCHEME="${STATE_SCHEME:-path}"
  P2P_PORT="${P2P_PORT:-30303}"; RPC_PORT="${RPC_PORT:-8545}"; RPC_ADDR="${RPC_ADDR:-127.0.0.1}"
  RPC_APIS="${RPC_APIS:-eth,net,web3,txpool,XDPoS}"
  STOP_TIMEOUT="${STOP_TIMEOUT:-300}"; RUNTIME_IMAGE="${RUNTIME_IMAGE:-ubuntu:24.04}"
  ETHSTATS="${ETHSTATS:-}"; EXTRA_FLAGS="${EXTRA_FLAGS:-}"
  VALIDATOR="${VALIDATOR:-false}"; COINBASE="${COINBASE:-}"
  CONTAINER="gp5-${NETWORK}"
  RPC_URL="http://127.0.0.1:${RPC_PORT}"
  case "$NETWORK" in
    apothem) NET_FLAGS=(--apothem --networkid 51); CHAIN_ID=0x33 ;;
    mainnet) NET_FLAGS=(--networkid 50);           CHAIN_ID=0x32 ;;
    *) die "NETWORK must be apothem or mainnet (got '$NETWORK')" ;;
  esac
}

is_running() { docker ps --format '{{.Names}}' | grep -qx "$CONTAINER"; }
exists()     { docker ps -a --format '{{.Names}}' | grep -qx "$CONTAINER"; }

set_config() { # set_config KEY VALUE  -> update or append in config.env
  if grep -q "^$1=" "$CONFIG"; then sed -i "s|^$1=.*|$1=$2|" "$CONFIG"
  else printf '%s=%s\n' "$1" "$2" >> "$CONFIG"; fi
}
keystore_addr() { # first account in data/keystore, as 0x...
  local f; f=$(ls "$DATA/keystore"/UTC--* 2>/dev/null | head -1)
  [ -n "$f" ] && echo "0x${f##*--}"
}
to_xdc() { echo "xdc${1#0x}"; }

rpc() { # rpc method [params-json]
  curl -s -m 10 -X POST -H 'Content-Type: application/json' \
    --data "{\"jsonrpc\":\"2.0\",\"method\":\"$1\",\"params\":${2:-[]},\"id\":1}" "$RPC_URL"
}
hex2dec() { [ -n "$1" ] && [ "$1" != null ] && printf '%d' "$1" || echo "-"; }

# ---------- commands ----------
cmd_setup() {
  info "Checking requirements"
  [ "$(uname -s)" = Linux ] || die "Linux only"
  [ "$(uname -m)" = x86_64 ] || die "Only amd64/x86_64 is supported by this script (found $(uname -m))"
  for t in curl jq; do
    if command -v "$t" >/dev/null; then ok "$t"; else
      warn "$t missing"; confirm "Install $t with apt?" && { apt-get update -qq && apt-get install -y -qq "$t"; } || die "$t is required"
    fi
  done
  if command -v docker >/dev/null; then ok "docker"; else
    warn "docker missing"; confirm "Install docker.io with apt?" && { apt-get update -qq && apt-get install -y -qq docker.io && systemctl enable --now docker; } || die "docker is required"
  fi
  docker info >/dev/null 2>&1 || die "docker is installed but not usable (try sudo, or add your user to the docker group)"

  info "Preparing folders"
  mkdir -p "$ROOT/bin" "$DATA" "$LOGS"
  if [ ! -f "$CONFIG" ]; then
    cp "$ROOT/config.env.example" "$CONFIG"
    warn "Created config.env - set NODE_NAME (and anything else) before starting:"
    echo "        nano $CONFIG"
  else ok "config.env exists"; fi
  load_config

  info "Downloading GP5 ${GETH_VERSION}"
  if [ -f "$BIN" ] && [ "${FORCE:-0}" != 1 ]; then ok "binary already present (use 'setup --force' to re-download)"
  else
    curl -fL --progress-bar -o "$BIN.tmp" "$GETH_URL" || die "download failed: $GETH_URL"
    mv "$BIN.tmp" "$BIN"; chmod +x "$BIN"
  fi
  SUM=$(sha256sum "$BIN" | cut -d' ' -f1)
  if [ -n "${GETH_SHA256:-}" ]; then
    [ "$SUM" = "$GETH_SHA256" ] && ok "sha256 matches" || die "sha256 mismatch: got $SUM expected $GETH_SHA256"
  else warn "no GETH_SHA256 pinned; downloaded binary sha256 = $SUM"; fi

  info "Testing binary inside $RUNTIME_IMAGE"
  docker run --rm -v "$BIN:/usr/local/bin/geth:ro" "$RUNTIME_IMAGE" geth version || die "binary does not run"

  local free; free=$(df -BG --output=avail "$DATA" | tail -1 | tr -dc 0-9)
  [ "$free" -lt 100 ] && warn "only ${free}G free disk - Apothem needs ~50G+, mainnet much more" || ok "${free}G free disk"

  echo; info "Setup done. Next:  ./gp5.sh start"
}

cmd_start() {
  load_config
  [ -x "$BIN" ] || die "binary missing. Run: ./gp5.sh setup"
  [ "$NODE_NAME" = my-gp5-node ] && warn "NODE_NAME is still the default - edit config.env so your node is identifiable"
  is_running && { ok "$CONTAINER is already running"; return; }
  exists && docker rm "$CONTAINER" >/dev/null

  local args=(geth --datadir /data "${NET_FLAGS[@]}"
    --syncmode "$SYNC_MODE" --state.scheme "$STATE_SCHEME"
    --identity "$NODE_NAME" --port "$P2P_PORT"
    --http --http.addr "$RPC_ADDR" --http.port "$RPC_PORT" --http.api "$RPC_APIS")
  [ "$RPC_ADDR" != 127.0.0.1 ] && args+=(--http.vhosts '*')
  if [ -n "$ETHSTATS" ]; then args+=(--ethstats "${NODE_NAME}:${ETHSTATS}")
  else warn "ETHSTATS is empty - the node will not appear on the stats page"; fi
  if [ "$VALIDATOR" = true ]; then
    [ -n "$COINBASE" ] || die "VALIDATOR=true but COINBASE is empty. Run: ./gp5.sh account create"
    local lc; lc=$(echo "${COINBASE#0x}" | tr 'A-F' 'a-f')
    compgen -G "$DATA/keystore/UTC--*--$lc" >/dev/null || die "no keystore file for $COINBASE in data/keystore"
    [ -s "$DATA/.password" ] || die "data/.password missing - needed to unlock $COINBASE"
    [ "$RPC_ADDR" = 127.0.0.1 ] || die "VALIDATOR=true needs RPC_ADDR=127.0.0.1 (the key is unlocked; never expose RPC)"
    args+=(--mine --unlock "$COINBASE" --password /data/.password --allow-insecure-unlock)
    if [[ "$EXTRA_FLAGS" == *--mine* || "$EXTRA_FLAGS" == *--unlock* ]]; then
      warn "EXTRA_FLAGS also has --mine/--unlock; remove them (VALIDATOR=true adds them)"
    fi
  fi
  # shellcheck disable=SC2206
  [ -n "$EXTRA_FLAGS" ] && args+=($EXTRA_FLAGS)

  info "Starting $CONTAINER ($NETWORK, $SYNC_MODE sync, $STATE_SCHEME scheme) as '$NODE_NAME'$([ "$VALIDATOR" = true ] && echo ", validator $(to_xdc "$COINBASE")")"
  docker run -d --name "$CONTAINER" --network host --restart unless-stopped \
    --stop-timeout "$STOP_TIMEOUT" \
    -v "$BIN:/usr/local/bin/geth:ro" -v "$DATA:/data" \
    "$RUNTIME_IMAGE" "${args[@]}" >/dev/null || die "docker run failed"
  ok "started. Check progress with: ./gp5.sh status"
}

cmd_stop() {
  load_config
  exists || { ok "$CONTAINER is not running"; return; }
  info "Stopping $CONTAINER cleanly (up to ${STOP_TIMEOUT}s so state is saved)"
  docker stop -t "$STOP_TIMEOUT" "$CONTAINER" >/dev/null && docker rm "$CONTAINER" >/dev/null && ok "stopped"
}

cmd_status() {
  load_config
  echo "${B}Node:${N}      $NODE_NAME  ($NETWORK, container $CONTAINER)"
  if ! is_running; then echo "${B}State:${N}     ${R}not running${N}  (./gp5.sh start)"; return 1; fi
  echo "${B}State:${N}     ${G}running${N}  $(docker ps --filter "name=^${CONTAINER}$" --format '{{.Status}}')"
  local ver; ver=$(rpc web3_clientVersion | jq -r '.result // empty')
  if [ -z "$ver" ]; then echo "${B}RPC:${N}       not answering yet (node may still be starting)"; return 0; fi
  local cid blk peers sync cur hi
  cid=$(rpc eth_chainId | jq -r .result)
  blk=$(hex2dec "$(rpc eth_blockNumber | jq -r .result)")
  peers=$(hex2dec "$(rpc net_peerCount | jq -r .result)")
  sync=$(rpc eth_syncing | jq -c .result)
  echo "${B}Client:${N}    $ver"
  echo "${B}Chain ID:${N}  $cid $([ "$cid" = "$CHAIN_ID" ] && echo "${G}(correct)${N}" || echo "${R}(expected $CHAIN_ID)${N}")"
  echo "${B}Block:${N}     $blk"
  echo "${B}Peers:${N}     $peers"
  if [ "$sync" = false ]; then echo "${B}Sync:${N}      ${G}synced${N}"
  else
    cur=$(hex2dec "$(echo "$sync" | jq -r .currentBlock)"); hi=$(hex2dec "$(echo "$sync" | jq -r .highestBlock)")
    [ "$hi" != - ] && [ "$hi" -gt 0 ] && echo "${B}Sync:${N}      $cur / $hi ($(awk "BEGIN{printf \"%.2f\", $cur*100/$hi}")%)"
  fi
  echo "${B}Disk:${N}      $(du -sh "$DATA" 2>/dev/null | cut -f1)"
  if [ -z "$ETHSTATS" ]; then echo "${B}Stats:${N}     off (set ETHSTATS in config.env)"
  else
    local st; st=$(docker logs --since 10m "$CONTAINER" 2>&1 | grep -i "stats" | tail -1)
    echo "${B}Stats:${N}     ${ETHSTATS#*@} as '$NODE_NAME'${st:+
           last log: ${st:0:120}}"
  fi
  if [ "$VALIDATOR" != true ]; then echo "${B}Validator:${N} off"
  else
    local mn role="not elected (standby/candidate)"
    mn=$(rpc XDPoS_getMasternodesByNumber '["latest"]')
    if echo "$mn" | grep -qi "${COINBASE#0x}"; then role="${G}ACTIVE masternode${N}"
    elif echo "$mn" | jq -e .error >/dev/null 2>&1; then role="unknown (check the masternode page)"; fi
    echo "${B}Validator:${N} $(to_xdc "$COINBASE") - $role"
    docker logs --since 1h "$CONTAINER" 2>&1 | grep -qi "HookPenalty.*${COINBASE#0x}" \
      && echo "           ${R}PENALTY logged for this coinbase in the last hour - check ./gp5.sh logs --errors${N}"
  fi
}

cmd_logs() {
  load_config; exists || die "$CONTAINER does not exist"
  if [ "${1:-}" = "--save" ]; then
    local f; f="$LOGS/${CONTAINER}-$(date +%Y%m%d-%H%M%S).log"
    docker logs "$CONTAINER" > "$f" 2>&1 && ok "saved to $f"
  elif [ "${1:-}" = "--errors" ]; then
    docker logs "$CONTAINER" 2>&1 | grep -E "WARN|ERROR|CRIT|BAD BLOCK|rewind|state missing" | tail -50
  else docker logs -f --tail "${1:-50}" "$CONTAINER"; fi
}

cmd_attach() {
  load_config; is_running || die "$CONTAINER is not running"
  if [ $# -gt 0 ]; then docker exec "$CONTAINER" geth attach --exec "$*" "$RPC_URL"
  else docker exec -it "$CONTAINER" geth attach "$RPC_URL"; fi
}

cmd_rpc() {
  load_config; [ $# -ge 1 ] || die "usage: ./gp5.sh rpc <method> [params-json]"
  rpc "$1" "${2:-[]}" | jq .
}

cmd_speed() {
  load_config; is_running || die "$CONTAINER is not running"
  local s=${1:-60} a b
  a=$(hex2dec "$(rpc eth_blockNumber | jq -r .result)"); info "Measuring for ${s}s from block $a..."
  sleep "$s"
  b=$(hex2dec "$(rpc eth_blockNumber | jq -r .result)")
  echo "block $b   $(( (b - a) / s )) blocks/s"
}

cmd_crashtest() {
  load_config; is_running || die "$CONTAINER is not running"
  echo "${Y}This hard-kills the node (simulates a crash/power loss) and checks where it resumes.${N}"
  confirm "Continue?" || return
  local before after
  before=$(hex2dec "$(rpc eth_blockNumber | jq -r .result)")
  info "Block before kill: $before"
  docker kill "$CONTAINER" >/dev/null && docker start "$CONTAINER" >/dev/null
  info "Waiting for RPC..."
  for _ in $(seq 1 60); do sleep 5; after=$(rpc eth_blockNumber | jq -r '.result // empty'); [ -n "$after" ] && break; done
  [ -z "$after" ] && die "node did not come back within 5 minutes - check ./gp5.sh logs --errors"
  after=$(hex2dec "$after")
  info "Block after restart: $after   (lost $(( before - after )) blocks)"
  if [ "$after" -eq 0 ] && [ "$before" -gt 0 ]; then echo "${R}FAIL: node reset to genesis${N}"
  elif [ $(( before - after )) -gt 90000 ]; then echo "${Y}WARN: lost more than 90k blocks${N}"
  else echo "${G}PASS: node resumed close to where it stopped${N}"; fi
  docker logs "$CONTAINER" 2>&1 | grep -E "state missing|rewind|Unclean|genesis" | tail -10
}

cmd_compare() {
  load_config; RPC="$RPC_URL" "$ROOT/tools/compare.sh" "${1:-30}" "$RPC_URL"
}

cmd_account() {
  load_config
  case "${1:-show}" in
    create)
      local existing; existing=$(keystore_addr)
      if [ -n "$existing" ]; then
        warn "an account already exists: $existing ($(to_xdc "$existing"))"
        set_config COINBASE "$existing"; ok "COINBASE set to it in config.env"; return
      fi
      mkdir -p "$DATA"
      if [ ! -s "$DATA/.password" ]; then
        (umask 077; head -c 16 /dev/urandom | od -An -tx1 | tr -d ' \n' > "$DATA/.password"; echo >> "$DATA/.password")
        ok "generated data/.password"
      fi
      info "Creating the node account (does not affect a running node)"
      docker run --rm -v "$BIN:/usr/local/bin/geth:ro" -v "$DATA:/data" "$RUNTIME_IMAGE" \
        geth account new --datadir /data --password /data/.password >/dev/null 2>&1 || die "account creation failed"
      local addr; addr=$(keystore_addr); [ -n "$addr" ] || die "no keystore file was written"
      set_config COINBASE "$addr"
      ok "address: $addr"
      ok "XDC format (use on the masternode page): $(to_xdc "$addr")"
      echo "  Back it up now:  ./gp5.sh account backup"
      echo "  Then propose it on the masternode page and run:  ./gp5.sh validator on" ;;
    show)
      local a; a=$(keystore_addr)
      [ -n "$a" ] || { echo "No account yet. Create one with: ./gp5.sh account create"; return; }
      echo "${B}Address:${N}   $a"
      echo "${B}XDC:${N}       $(to_xdc "$a")"
      echo "${B}Password:${N}  $([ -s "$DATA/.password" ] && echo "data/.password present" || echo "${R}data/.password missing${N}")"
      echo "${B}COINBASE:${N}  ${COINBASE:-not set in config.env}" ;;
    backup)
      [ -n "$(keystore_addr)" ] || die "no account to back up"
      mkdir -p "$ROOT/backups"
      local f; f="$ROOT/backups/gp5-key-$(date +%Y%m%d-%H%M%S).tar.gz"
      (umask 077; tar czf "$f" -C "$DATA" keystore .password) && ok "saved $f"
      echo "  Copy it off this server, e.g. from your laptop:  scp root@<server-ip>:$f ." ;;
    *) die "usage: ./gp5.sh account [create|show|backup]" ;;
  esac
}

cmd_validator() {
  load_config
  case "${1:-}" in
    on)
      [ -n "$COINBASE" ] || COINBASE=$(keystore_addr)
      [ -n "$COINBASE" ] || die "no account yet. Run: ./gp5.sh account create"
      set_config COINBASE "$COINBASE"; set_config VALIDATOR true
      ok "validator enabled for $(to_xdc "$COINBASE")"
      is_running && { info "Restarting to apply"; cmd_stop; load_config; cmd_start; } ;;
    off)
      set_config VALIDATOR false; ok "validator disabled"
      is_running && { info "Restarting to apply"; cmd_stop; load_config; cmd_start; } ;;
    *) die "usage: ./gp5.sh validator on|off" ;;
  esac
}

cmd_reset() {
  load_config
  echo "${R}This deletes all chain data in $DATA and resyncs from scratch.${N}"
  confirm "Are you sure?" || return
  cmd_stop
  rm -rf "${DATA:?}"/* && ok "data deleted. Start again with ./gp5.sh start"
}

cmd_help() { cat <<EOF
${B}gp5.sh${N} - run and test an XDC GP5 (modern geth) node

${B}First time${N}
  ./gp5.sh setup              check requirements, create config.env, download GP5
  nano config.env             set NODE_NAME (and network, ports...)
  ./gp5.sh start              start the node

${B}Daily use${N}
  ./gp5.sh status             block, peers, sync %, disk
  ./gp5.sh logs [N]           follow the live log (last N lines, default 50)
  ./gp5.sh logs --errors      show recent warnings/errors
  ./gp5.sh logs --save        save the full log to logs/ (attach to bug reports)
  ./gp5.sh attach             open the geth console (over RPC)
  ./gp5.sh attach "eth.blockNumber"   run one console command
  ./gp5.sh rpc eth_blockNumber        raw JSON-RPC call
  ./gp5.sh stop | restart     clean stop (saves state) / restart

${B}Masternode${N}
  ./gp5.sh account create     create the node's coinbase address (+ password file)
  ./gp5.sh account show       show the address in 0x and xdc format
  ./gp5.sh account backup     save keystore + password to backups/
  ./gp5.sh validator on|off   load the key and sign blocks when elected (restarts the node)

${B}Testing${N}
  ./gp5.sh speed [secs]       measure sync speed (blocks/s)
  ./gp5.sh crashtest          hard-kill the node and check it resumes
  ./gp5.sh compare [N]        compare N random blocks with the public RPC

${B}Maintenance${N}
  ./gp5.sh setup --force      re-download the binary (after changing GETH_VERSION)
  ./gp5.sh reset              delete chain data and resync

Add -y to skip confirmation prompts.
EOF
}

# ---------- main ----------
ASSUME_YES=0; FORCE=0; ARGS=()
for a in "$@"; do
  case "$a" in -y|--yes) ASSUME_YES=1 ;; --force) FORCE=1 ;; *) ARGS+=("$a") ;; esac
done
set -- "${ARGS[@]+"${ARGS[@]}"}"
CMD="${1:-help}"; shift || true
case "$CMD" in
  setup) cmd_setup ;;
  start) cmd_start ;;
  stop) cmd_stop ;;
  restart) cmd_stop; cmd_start ;;
  status) cmd_status ;;
  logs) cmd_logs "$@" ;;
  attach) cmd_attach "$@" ;;
  rpc) cmd_rpc "$@" ;;
  speed) cmd_speed "$@" ;;
  crashtest) cmd_crashtest ;;
  compare) cmd_compare "$@" ;;
  account) cmd_account "$@" ;;
  validator) cmd_validator "$@" ;;
  reset) cmd_reset ;;
  help|-h|--help) cmd_help ;;
  *) echo "Unknown command: $CMD"; echo; cmd_help; exit 1 ;;
esac
