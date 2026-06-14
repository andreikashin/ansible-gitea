#!/usr/bin/env bash
set -euo pipefail

: "${PROXMOX_RSYNC_LOCAL_BACKUP_FILE:?PROXMOX_RSYNC_LOCAL_BACKUP_FILE is required}"
: "${PROXMOX_REMOTE_BACKUP_SIZE:?PROXMOX_REMOTE_BACKUP_SIZE is required}"
: "${PROXMOX_RSYNC_POLL_ATTEMPTS:?PROXMOX_RSYNC_POLL_ATTEMPTS is required}"
: "${PROXMOX_RSYNC_POLL_INTERVAL:?PROXMOX_RSYNC_POLL_INTERVAL is required}"

vm_id="${PROXMOX_VM_ID:-unknown}"
inventory_hostname="${PROXMOX_INVENTORY_HOSTNAME:-unknown}"
job_id="${PROXMOX_RSYNC_JOB_ID:-}"
poll_attempts="${PROXMOX_RSYNC_POLL_ATTEMPTS}"
poll_interval="${PROXMOX_RSYNC_POLL_INTERVAL}"

is_integer() {
  [[ "$1" =~ ^[0-9]+$ ]]
}

if ! is_integer "${PROXMOX_REMOTE_BACKUP_SIZE}" || ! is_integer "${poll_attempts}" || ! is_integer "${poll_interval}"; then
  echo "Invalid rsync polling configuration for VMID ${vm_id} on ${inventory_hostname}" >&2
  exit 1
fi

read_async_state() {
  async_finished=0
  async_rc=-1

  if [ -n "${job_id}" ]; then
    async_state_file="${HOME}/.ansible_async/${job_id}"
    if [ -f "${async_state_file}" ]; then
      read -r async_finished async_rc < <(
        python3 - "${async_state_file}" <<'PY'
import json
import pathlib
import sys

path = pathlib.Path(sys.argv[1])
try:
    data = json.loads(path.read_text(encoding='utf-8'))
    print(f"{int(data.get('finished', 0))} {int(data.get('rc', -1))}")
except Exception:
    print('0 -1')
PY
      )
    fi
  fi
}

check_candidate_size() {
  candidate_path="$1"

  if [ -e "${candidate_path}" ]; then
    candidate_size="$(stat -c '%s' "${candidate_path}" 2>/dev/null || echo -1)"

    if [ "${candidate_size}" -eq "${PROXMOX_REMOTE_BACKUP_SIZE}" ]; then
      return 0
    fi
  fi

  return 1
}

copy_verified() {
  read_async_state

  if [ "${async_finished}" -eq 1 ] && [ "${async_rc}" -eq 0 ]; then
    return 0
  fi

  if check_candidate_size "${PROXMOX_RSYNC_LOCAL_BACKUP_FILE}"; then
    return 0
  fi

  local_backup_dir="$(dirname "${PROXMOX_RSYNC_LOCAL_BACKUP_FILE}")"
  local_backup_base="$(basename "${PROXMOX_RSYNC_LOCAL_BACKUP_FILE}")"
  temp_candidate="$(find "${local_backup_dir}" -maxdepth 1 -type f -name ".${local_backup_base}.*" -print -quit 2>/dev/null || true)"

  if [ -n "${temp_candidate}" ] && check_candidate_size "${temp_candidate}"; then
    return 0
  fi

  return 1
}

attempt=1
while [ "${attempt}" -le "${poll_attempts}" ]; do
  if copy_verified; then
    exit 0
  fi

  if [ "${attempt}" -lt "${poll_attempts}" ]; then
    sleep "${poll_interval}"
  fi

  attempt=$((attempt + 1))
done

echo "Rsync copy for VMID ${vm_id} on ${inventory_hostname} was not verified after ${poll_attempts} checks." >&2
exit 1
