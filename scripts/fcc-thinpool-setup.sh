#!/usr/bin/env bash
# Creates the device-mapper thin pool backing containerd's devmapper
# snapshotter. Installed to /usr/local/sbin/fcc-thinpool-setup by
# 13-configure-containerd.sh and run by fcc-thinpool.service at boot.
#
# Must run before firecracker-containerd starts: the snapshotter expects the
# pool to already exist. Loop devices and dm targets are runtime-only state, so
# this runs on every WSL boot, but the backing files persist.
#
# Idempotent: an already-active pool is left untouched.

set -euo pipefail

POOL_NAME="${POOL_NAME:-fcc-thinpool}"
DIR="${DIR:-/var/lib/firecracker-containerd/snapshotter/devmapper}"
DATA_SIZE="${DATA_SIZE:-20G}"
META_SIZE="${META_SIZE:-256M}"

DATA_FILE="${DIR}/data"
META_FILE="${DIR}/metadata"

log() { printf '[thinpool] %s\n' "$*"; }

if dmsetup info "$POOL_NAME" >/dev/null 2>&1; then
  log "pool '${POOL_NAME}' already active"
  exit 0
fi

mkdir -p "$DIR"

fresh=0
if [ ! -f "$DATA_FILE" ]; then
  truncate -s "$DATA_SIZE" "$DATA_FILE"
  fresh=1
  log "created data file (${DATA_SIZE}, sparse)"
fi
if [ ! -f "$META_FILE" ]; then
  truncate -s "$META_SIZE" "$META_FILE"
  fresh=1
  log "created metadata file (${META_SIZE}, sparse)"
fi

# Reuse an existing loop association if one survived; otherwise attach a new
# device. Attaching the same file twice would give the pool two distinct
# devices over identical storage.
attach_loop() {
  local file="$1" dev
  dev="$(losetup --output NAME --noheadings --associated "$file" | head -1 | tr -d ' ')"
  if [ -z "$dev" ]; then
    dev="$(losetup --find --show "$file")"
  fi
  printf '%s' "$dev"
}

DATA_DEV="$(attach_loop "$DATA_FILE")"
META_DEV="$(attach_loop "$META_FILE")"
log "data=${DATA_DEV} metadata=${META_DEV}"

# A thin-pool reads its metadata device on activation. Unzeroed garbage in a
# newly created sparse file is interpreted as corrupt metadata, so zero the
# superblock on first creation only - doing it later would destroy the pool.
if [ "$fresh" -eq 1 ]; then
  dd if=/dev/zero of="$META_DEV" bs=4096 count=1 conv=notrunc status=none
  log "zeroed metadata superblock"
fi

SECTOR_SIZE=512
DATA_BYTES="$(blockdev --getsize64 -q "$DATA_DEV")"
LENGTH_SECTORS=$(( DATA_BYTES / SECTOR_SIZE ))
DATA_BLOCK_SIZE=128      # 64 KiB allocation unit
LOW_WATER_MARK=32768

TABLE="0 ${LENGTH_SECTORS} thin-pool ${META_DEV} ${DATA_DEV} ${DATA_BLOCK_SIZE} ${LOW_WATER_MARK} 1 skip_block_zeroing"

if dmsetup reload "$POOL_NAME" --table "$TABLE" 2>/dev/null; then
  dmsetup resume "$POOL_NAME"
  log "reloaded existing pool '${POOL_NAME}'"
else
  dmsetup create "$POOL_NAME" --table "$TABLE"
  log "created pool '${POOL_NAME}' (${LENGTH_SECTORS} sectors)"
fi

dmsetup status "$POOL_NAME" | sed 's/^/[thinpool] status: /'
