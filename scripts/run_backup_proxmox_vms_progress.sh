#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "${script_dir}/.." && pwd)"
playbook="${repo_root}/backup_proxmox_vms.yml"
inventory="${repo_root}/inventory.ini"

ansible_cmd=(ansible-playbook -i "${inventory}" "${playbook}")
if [ "$#" -gt 0 ]; then
  ansible_cmd+=("$@")
fi

if [ -t 2 ]; then
  color_reset=$'\033[0m'
  color_bold=$'\033[1m'
  color_dim=$'\033[2m'
  color_cyan=$'\033[1;36m'
  color_yellow=$'\033[1;33m'
  color_green=$'\033[1;32m'
else
  color_reset=''
  color_bold=''
  color_dim=''
  color_cyan=''
  color_yellow=''
  color_green=''
fi

cleanup() {
  if [ -n "${progress_pid:-}" ] && kill -0 "${progress_pid}" 2>/dev/null; then
    kill "${progress_pid}" 2>/dev/null || true
    wait "${progress_pid}" 2>/dev/null || true
  fi
}

trap cleanup INT TERM

render_bar() {
  local percent="$1"
  local width="${2:-18}"
  local filled=$(( percent * width / 100 ))
  local empty=$(( width - filled ))
  local filled_segment=""
  local empty_segment=""

  if [ "${filled}" -gt 0 ]; then
    filled_segment="$(printf '%*s' "${filled}" '' | tr ' ' '=')"
  fi

  if [ "${empty}" -gt 0 ]; then
    empty_segment="$(printf '%*s' "${empty}" '' | tr ' ' '-')"
  fi

  printf '%s%s' "${filled_segment}" "${empty_segment}"
}

render_progress_line() {
  local line="$1"
  local target_label="${2:-}"
  local bytes=""
  local percent=""
  local tail=""
  local bar=""
  local progress_color="${color_cyan}"

  bytes="$(printf '%s\n' "${line}" | awk '{ print $1 }')"
  percent="$(printf '%s\n' "${line}" | awk '{ gsub(/%$/, "", $2); print $2 }')"
  tail="$(printf '%s\n' "${line}" | awk '{ $1 = ""; $2 = ""; sub(/^[[:space:]]+/, "", $0); print $0 }')"

  if ! [[ "${percent}" =~ ^[0-9]+$ ]]; then
    if [ -n "${target_label}" ]; then
      printf '\r\033[K%srsync%s %s%s%s %s' "${color_cyan}" "${color_reset}" "${color_dim}" "${target_label}" "${color_reset}" "${line}"
    else
      printf '\r\033[K%srsync%s %s' "${color_cyan}" "${color_reset}" "${line}"
    fi
    return 0
  fi

  if [ "${percent}" -ge 100 ]; then
    progress_color="${color_green}"
  elif [ "${percent}" -ge 75 ]; then
    progress_color="${color_yellow}"
  fi

  bar="$(render_bar "${percent}" 18)"

  printf '\r\033[K%srsync%s ' "${color_cyan}" "${color_reset}"
  if [ -n "${target_label}" ]; then
    printf '%s%s%s ' "${color_dim}" "${target_label}" "${color_reset}"
  fi
  printf '%s[%s]%s ' "${color_bold}" "${bar}" "${color_reset}"
  printf '%s%3s%%%s ' "${progress_color}" "${percent}" "${color_reset}"
  printf '%s%s%s' "${color_dim}" "${bytes}" "${color_reset}"
  if [ -n "${tail}" ]; then
    printf ' %s%s%s' "${color_dim}" "${tail}" "${color_reset}"
  fi
}

monitor_progress() {
  local last_rendered=""
  local latest_log=""
  local latest_label=""
  local progress_line=""
  local rendered_line=""

  while true; do
    rendered_line=""
    latest_label=""
    latest_log="$(find /tmp -maxdepth 1 -type f -name 'ansible-rsync-*.log' -printf '%T@ %p\n' 2>/dev/null | sort -n | tail -n1 | cut -d' ' -f2- || true)"

    if [ -n "${latest_log}" ] && [ -f "${latest_log}" ]; then
      if [[ "$(basename "${latest_log}")" =~ ^ansible-rsync-(.*)-([0-9]+)\.log$ ]]; then
        latest_label="${BASH_REMATCH[1]}/VM${BASH_REMATCH[2]}"
      else
        latest_label="$(basename "${latest_log}")"
        latest_label="${latest_label#ansible-rsync-}"
        latest_label="${latest_label%.log}"
      fi

      progress_line="$(awk 'NF { line = $0 } END { print line }' "${latest_log}" 2>/dev/null || true)"
      if [ -n "${progress_line}" ]; then
        rendered_line="$(render_progress_line "${progress_line}" "${latest_label}")"
      fi
    fi

    if [ -z "${rendered_line}" ]; then
      if [ -n "${latest_label}" ]; then
        rendered_line="$(printf '\r\033[K%srsync%s %s%s%s %swaiting for progress...%s' "${color_cyan}" "${color_reset}" "${color_dim}" "${latest_label}" "${color_reset}" "${color_dim}" "${color_reset}")"
      else
        rendered_line="$(printf '\r\033[K%srsync%s %swaiting for progress...%s' "${color_cyan}" "${color_reset}" "${color_dim}" "${color_reset}")"
      fi
    fi

    if [ "${rendered_line}" != "${last_rendered}" ]; then
      printf '%s' "${rendered_line}" >&2
      last_rendered="${rendered_line}"
    fi

    sleep 1
  done
}

if [ -t 2 ]; then
  monitor_progress &
  progress_pid=$!
fi

set +e
"${ansible_cmd[@]}"
status=$?
set -e

if [ -n "${progress_pid:-}" ] && kill -0 "${progress_pid}" 2>/dev/null; then
  kill "${progress_pid}" 2>/dev/null || true
  wait "${progress_pid}" 2>/dev/null || true
fi

if [ -t 2 ]; then
  printf '\r\033[K' >&2
  printf '\n' >&2
fi

exit "${status}"
