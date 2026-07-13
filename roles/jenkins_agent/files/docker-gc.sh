#!/usr/bin/env bash
#
# Periodic Docker garbage collection for the Jenkins build agent.
#
# Docker never reclaims images on its own: `docker push` uploads a copy to the
# registry (Harbor) but leaves the built image in the local store, so images
# accumulate build after build. This script drops them, while protecting base
# images (e.g. cimg/*) that are expensive to re-pull and meant to stay cached.
#
# Build-cache growth is bounded separately by the buildkit GC policy in
# /etc/docker/daemon.json; here we also run a manual prune as a safety net.
#
# Configuration is read from the environment (see docker-gc.env):
#   BUILD_CACHE_KEEP     - upper bound for buildkit cache, e.g. "10GB"
#   IMAGE_MAX_AGE_HOURS  - only remove unused images older than this
#   PROTECT_REGEX        - never remove images whose ref matches this ERE
set -uo pipefail

BUILD_CACHE_KEEP="${BUILD_CACHE_KEEP:-10GB}"
IMAGE_MAX_AGE_HOURS="${IMAGE_MAX_AGE_HOURS:-24}"
PROTECT_REGEX="${PROTECT_REGEX:-}"

log() { echo "[docker-gc] $(date -Is) $*"; }

log "build cache prune (keep <= ${BUILD_CACHE_KEEP})"
docker builder prune --force --keep-storage "${BUILD_CACHE_KEEP}" >/dev/null 2>&1 || true

log "removing dangling images"
docker image prune --force >/dev/null 2>&1 || true

now=$(date +%s)
max_age_secs=$(( IMAGE_MAX_AGE_HOURS * 3600 ))

log "removing unused images older than ${IMAGE_MAX_AGE_HOURS}h (protect: '${PROTECT_REGEX:-none}')"
for id in $(docker images --format '{{.ID}}' | sort -u); do
  ref=$(docker image inspect "$id" --format '{{ join .RepoTags "," }}' 2>/dev/null || echo "")

  # keep protected base images regardless of age
  if [[ -n "$PROTECT_REGEX" && -n "$ref" ]] && echo "$ref" | grep -qE "$PROTECT_REGEX"; then
    continue
  fi

  created=$(docker image inspect "$id" --format '{{ .Created }}' 2>/dev/null || echo "")
  created_epoch=$(date -d "$created" +%s 2>/dev/null || echo "$now")
  if (( now - created_epoch >= max_age_secs )); then
    # `docker image rm` refuses images in use by a container, so an in-flight
    # build is never harmed; failures are ignored on purpose.
    if docker image rm "$id" >/dev/null 2>&1; then
      log "removed ${ref:-$id}"
    fi
  fi
done

log "done"
