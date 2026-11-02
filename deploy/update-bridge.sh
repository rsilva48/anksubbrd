#!/usr/bin/env bash
# Updates the Docker bridge to the newest version tag on origin/main.
#
# Meant for a systemd timer: it exits quietly when the checkout is current,
# rebuilds the container only when proxy/ changed, waits for the health check
# and rolls back to the previous commit when the new version does not answer.
# A failed tag is skipped until a newer one exists (FORCE=1 retries it).
#
# Settings (environment): BRIDGE_DIR, BRIDGE_BRANCH, BRIDGE_CONTAINER,
# BRIDGE_HEALTH_URL, HEALTH_TIMEOUT, FORCE.
set -euo pipefail

# Everything runs inside main so bash has parsed the whole file before the
# fast-forward below replaces it with a newer version.
main() {
  local bridge_dir=${BRIDGE_DIR:-/opt/anksubbrd}
  local branch=${BRIDGE_BRANCH:-main}
  local container=${BRIDGE_CONTAINER:-ani-bridge}
  local health_url=${BRIDGE_HEALTH_URL:-http://127.0.0.1:8787/health}
  local health_timeout=${HEALTH_TIMEOUT:-90}

  cd "$bridge_dir"
  export DOCKER_CONFIG="$PWD/.docker"
  local git_dir
  git_dir=$(git rev-parse --absolute-git-dir)
  exec 9>"$git_dir/bridge-update.lock"
  if command -v flock >/dev/null; then
    flock -n 9 || { log 'Otra actualización está en curso.'; return 0; }
  fi

  git fetch --quiet --tags origin "$branch"
  local target_tag target current
  target_tag=$(git describe --tags --abbrev=0 --match 'v[0-9]*.[0-9]*.[0-9]*' "origin/$branch")
  target=$(git rev-parse "$target_tag^{commit}")
  current=$(git rev-parse HEAD)

  if [[ "$current" == "$target" ]] || git merge-base --is-ancestor "$target" "$current"; then
    log "Sin cambios: $target_tag ya está desplegado."
    return 0
  fi
  if ! git merge-base --is-ancestor "$current" "$target"; then
    log "HEAD $(git rev-parse --short HEAD) no es ancestro de $target_tag; revisa el checkout manualmente."
    return 1
  fi
  local failed_file="$git_dir/bridge-update-failed"
  if [[ -f "$failed_file" && "$(cat "$failed_file")" == "$target" && "${FORCE:-0}" != 1 ]]; then
    log "$target_tag falló antes; se omite hasta que exista una versión nueva (FORCE=1 para reintentar)."
    return 0
  fi

  local rebuild=false
  if bridge_changed "$current" "$target"; then rebuild=true; fi
  git merge --ff-only --quiet "$target"
  log "Checkout actualizado a $target_tag ($(git rev-parse --short HEAD))."
  if [[ "$rebuild" == false ]]; then
    log 'El código del bridge no cambió; el contenedor sigue en ejecución sin reconstruirse.'
    return 0
  fi

  if deploy "$container" "$health_url" "$health_timeout"; then
    rm -f "$failed_file"
    log "Bridge actualizado a $target_tag — $(git log -1 --format='%cs — %s')"
    docker inspect -f '{{.State.Status}} {{if .State.Health}}{{.State.Health.Status}}{{end}}' "$container"
    return 0
  fi

  log "La verificación de salud falló con $target_tag; restaurando $(git rev-parse --short "$current")."
  printf '%s\n' "$target" > "$failed_file"
  git reset --keep "$current"
  deploy "$container" "$health_url" "$health_timeout" || log 'La versión anterior tampoco respondió; revisa docker compose logs.'
  return 1
}

log() {
  printf '[%s] %s\n' "$(date -u +%FT%TZ)" "$*"
}

# Every commit bumps "version" in proxy/package*.json; that alone must not
# restart the container (it would cut active playback sessions). Dependency
# changes also touch ranges, "resolved" or "integrity" lines, so they count.
bridge_changed() {
  local from=$1 to=$2 file other
  while IFS= read -r file; do
    [[ -n "$file" ]] || continue
    case "$file" in
      proxy/package.json|proxy/package-lock.json)
        other=$(git diff -U0 "$from" "$to" -- "$file" | grep -E '^[+-]' | grep -vE '^(\+\+\+|---) ' \
          | grep -vE '^[+-][[:space:]]*"version": "[^"]*",?[[:space:]]*$' || true)
        if [[ -n "$other" ]]; then return 0; fi ;;
      *) return 0 ;;
    esac
  done < <(git diff --name-only "$from" "$to" -- proxy)
  return 1
}

healthy() {
  local container=$1 health_url=$2 state
  curl --noproxy '*' --fail --silent --show-error --max-time 5 "$health_url" >/dev/null 2>&1 || return 1
  state=$(docker inspect -f '{{.State.Status}} {{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}' "$container" 2>/dev/null) || return 1
  [[ "$state" == 'running healthy' || "$state" == 'running none' ]]
}

deploy() {
  local container=$1 health_url=$2 timeout=$3 waited=0
  docker compose up -d --build --remove-orphans || return 1
  until healthy "$container" "$health_url"; do
    if (( waited >= timeout )); then return 1; fi
    sleep 3
    waited=$((waited + 3))
  done
}

main "$@"; exit
