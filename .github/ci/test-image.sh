#!/bin/bash
#
# End-to-end test of a built image. Used by .github/workflows/test-image.yml
# and runnable locally against any local image:
#
#   .github/ci/test-image.sh <image> [phpy]
#
# <image>  Image to test (must already exist locally).
# [phpy]   "true" to also test the PHP embed + phpy build (default: false).
#
# Starts a throwaway container, checks that it runs, that the hardening is in
# place, and serves a minimal Django site (.github/ci/django-site) through
# the real flow: WWW_USER runs the Procfile script (via its sudo rule) and
# Caddy routes the requests to gunicorn. The container is always removed.
#

set -euo pipefail

IMAGE="${1:?Usage: $0 <image> [phpy: true|false]}"
PHPY="${2:-false}"

CI_DIR="$(cd "$(dirname "$0")" && pwd)"
NAME="ci-test-image-$$"
SITE="ci-test.example"
SITE_DIR="/var/www/sites/$SITE"
APP_USER="admin"
SUDO_RULE="(root) NOPASSWD: /scripts/start_procfile_supervisord.sh"

log() { echo "--- $*"; }

fail() {
    echo "::error::$*"
    echo "--- container logs (last 80 lines)"
    docker logs "$NAME" 2>&1 | tail -80 || true
    exit 1
}

cleanup() { docker rm -f "$NAME" >/dev/null 2>&1 || true; }
trap cleanup EXIT

in_ctr() { docker exec "$NAME" "$@"; }
as_app() { docker exec -u "$APP_USER" "$NAME" "$@"; }

# Retries a command for up to $1 seconds (1 try per second).
retry() {
    local seconds="$1"
    shift
    local i
    for ((i = 0; i < seconds; i++)); do
        if "$@" >/dev/null 2>&1; then
            return 0
        fi
        sleep 1
    done
    return 1
}

# https GET through Caddy inside the container, resolving the test domain to
# localhost (on-demand TLS with Caddy's internal issuer, hence -k).
fetch() {
    in_ctr curl -sk --max-time 10 --resolve "$SITE:443:127.0.0.1" "https://$SITE$1"
}

body_is() { [ "$(fetch "$1")" = "$2" ]; }

expect_body() {
    local path="$1" expected="$2"
    retry 30 body_is "$path" "$expected" \
        || fail "GET $path returned '$(fetch "$path" || true)', expected '$expected'"
    echo "GET $path -> $expected"
}

# --------------------------------------------------------------------------
log "Start container from $IMAGE"
docker run -d --name "$NAME" \
    -e CADDY_DEBUG= \
    -e CADDY_EMAIL=admin@example.com \
    -e CADDY_LOG_SIZE=100mb \
    -e CADDY_LOG_KEEP=5 \
    -e CADDY_HTTPS_ISSUER=internal \
    -e CADDY_HTTPS_ALLOW_ANY_HOST=false \
    -e WWW_ROOT_PATH=/var/www/sites \
    -e WWW_USER="$APP_USER" \
    -e SITES_DIR="/home/$APP_USER/sites" \
    -e EDITOR=vim \
    -e VISUAL=vim \
    "$IMAGE" >/dev/null

# Wait for the supervised processes to be RUNNING, not just the container up.
all_running() {
    local status
    status=$(in_ctr supervisorctl status 2>/dev/null) || return 1
    for program in caddy cron sshd; do
        echo "$status" | grep -q "^$program .*RUNNING" || return 1
    done
}
retry 60 all_running || fail "caddy, cron and sshd did not all reach RUNNING"
in_ctr supervisorctl status

# --------------------------------------------------------------------------
log "Static checks"
in_ctr bash -n /scripts/start_procfile_supervisord.sh || fail "bash -n failed: start_procfile_supervisord.sh"
in_ctr bash -n /usr/local/bin/entrypoint.sh || fail "bash -n failed: entrypoint.sh"
in_ctr bash -n "/home/$APP_USER/.bashrc" || fail "bash -n failed: .bashrc"
in_ctr caddy validate --config /etc/caddy/Caddyfile --adapter caddyfile >/dev/null 2>&1 \
    || fail "caddy validate failed"
in_ctr sshd -t || fail "sshd -t failed"
echo "bash -n, caddy validate and sshd -t OK"

# --------------------------------------------------------------------------
log "Hardening checks"

# WWW_USER may only run the Procfile script as root, nothing else.
rules=$(as_app sudo -n -l 2>/dev/null \
    | sed -n '/may run the following commands/,$p' | tail -n +2 | sed 's/^ *//')
[ "$rules" = "$SUDO_RULE" ] || fail "unexpected sudo rules for $APP_USER: $rules"
if as_app sudo -n true >/dev/null 2>&1; then
    fail "$APP_USER can run arbitrary commands with sudo"
fi
echo "sudo: only '$SUDO_RULE'"

# Directories root writes to (or runs from) must not be writable by others.
for path in /scripts /scripts/start_procfile_supervisord.sh /var/log/caddy /usr/local/bin/entrypoint.sh; do
    owner=$(in_ctr stat -c '%U' "$path")
    [ "$owner" = "root" ] || fail "$path is owned by $owner, expected root"
    if [ -n "$(in_ctr find "$path" -maxdepth 0 -perm /022)" ]; then
        fail "$path is writable by group or others"
    fi
done
echo "/scripts, /var/log/caddy and entrypoint.sh: root, not group/other writable"

# No SSH keys baked into the image.
ssh_files=$(in_ctr ls -A "/home/$APP_USER/.ssh")
[ "$ssh_files" = "known_hosts" ] || fail "unexpected files in ~/.ssh: $ssh_files"
echo "~/.ssh: only known_hosts"

# Network/recon tools are opt-in (NETWORK_TOOLS_ENABLE=1).
for tool in nmap socat; do
    if in_ctr sh -c "command -v $tool" >/dev/null 2>&1; then
        fail "$tool is installed (should only be with NETWORK_TOOLS_ENABLE=1)"
    fi
done
echo "nmap and socat not installed"

# Environment for interactive shells, written by the entrypoint.
in_ctr grep -qx "export SITES_DIR=/home/$APP_USER/sites" /etc/container-env.sh \
    || fail "/etc/container-env.sh missing or without SITES_DIR"
[ "$(as_app bash -ic 'echo "$SITES_DIR"' 2>/dev/null | tail -1)" = "/home/$APP_USER/sites" ] \
    || fail "interactive shell of $APP_USER does not get SITES_DIR"
echo "/etc/container-env.sh OK and loaded by the bashrc"

# --------------------------------------------------------------------------
log "Django site end to end (Procfile web + api with CADDY_ROUTE_PATH)"
in_ctr mkdir -p "$SITE_DIR"
docker cp "$CI_DIR/django-site" "$NAME:$SITE_DIR/current"
in_ctr chown -R "$APP_USER:$APP_USER" "$SITE_DIR"
as_app bash -c "cd '$SITE_DIR/current' && python3 -m venv venv \
    && venv/bin/pip install -q --disable-pip-version-check -r requirements.txt" \
    || fail "could not install the test site's requirements"

# As WWW_USER, like the deployer does: the script re-runs itself through sudo.
as_app /scripts/start_procfile_supervisord.sh "$SITE" || fail "start_procfile_supervisord.sh failed"

site_running() {
    local status
    status=$(in_ctr supervisorctl status 2>/dev/null) || return 1
    echo "$status" | grep -q "^django-$SITE-web .*RUNNING" \
        && echo "$status" | grep -q "^django-$SITE-api .*RUNNING"
}
retry 60 site_running || fail "web and api processes of the test site did not reach RUNNING"

expect_body "/" "ci-test web ok"
expect_body "/api/ping" "ci-test api ok"
expect_body "/static/ci-test.txt" "ci-test static ok"

# --------------------------------------------------------------------------
if [ "$PHPY" = "true" ]; then
    log "PHP embed + phpy"
    in_ctr php -v
    in_ctr php -r 'exit(version_compare(PHP_VERSION, "8.5.12", ">=") ? 0 : 1);' \
        || fail "PHP $(in_ctr php -r 'echo PHP_VERSION;') is older than 8.5.12 (CVE-2026-109618/109619)"
    modules=$(in_ctr php -m)
    for module in openssl curl mbstring; do
        echo "$modules" | grep -qix "$module" || fail "PHP module $module missing"
    done
    echo "PHP modules OK (openssl, curl, mbstring)"
    result=$(as_app python3 -c 'import phpy; print(phpy.call("strtoupper", "ci-test phpy ok"))') \
        || fail "import phpy or phpy.call failed"
    [ "$result" = "CI-TEST PHPY OK" ] || fail "phpy.call returned '$result'"
    echo "phpy.call('strtoupper', ...) -> $result"
fi

log "All checks passed"
