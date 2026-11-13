#!/bin/bash
#
# Container entrypoint: runs as root on every container start, then replaces
# itself with the main process (by default supervisord), which keeps PID 1
# and the container's environment.
#

set -e

APP_USER="${WWW_USER:-admin}"

# Expose select container environment variables to interactive shells.
# SSH sessions don't inherit the container's own environment, so this makes
# them available to config/bash/bashrc without needing sudo to read them
# from /proc/1/environ. Values are written with printf %q so that quotes or
# "$" in a value can't break (or run code from) the sourced file.
# DEPLOYER_DIR/DEPLOYER_HOST are only set if passed to the container
# (docker-compose.yml doesn't pass them by default), as before.
{
    printf 'export EDITOR=%q\n' "${EDITOR:-vim}"
    printf 'export VISUAL=%q\n' "${VISUAL:-vim}"
    printf 'export SITES_DIR=%q\n' "${SITES_DIR:-/home/${APP_USER}/sites}"
    printf 'export DEPLOYER_DIR=%q\n' "${DEPLOYER_DIR:-}"
    printf 'export DEPLOYER_HOST=%q\n' "${DEPLOYER_HOST:-}"
} > /etc/container-env.sh
chown root:root /etc/container-env.sh
chmod 644 /etc/container-env.sh

# Fix ownership/permissions on an optionally mounted ~/.ssh for APP_USER.
# No keys are baked into the image: SSH access only works if authorized_keys
# (and optionally a client id_rsa/id_rsa.pub) are mounted there from the
# host. SSH is strict about ownership/mode, which a host bind mount won't
# generally match, so this re-applies them on every container start. If
# files are added or changed after the container is already running,
# restart it to have this run again.
SSH_HOME="/home/${APP_USER}/.ssh"
if [ -d "${SSH_HOME}" ]; then
    chown -R "${APP_USER}:${APP_USER}" "${SSH_HOME}"
    chmod 700 "${SSH_HOME}"
    [ -f "${SSH_HOME}/authorized_keys" ] && chmod 600 "${SSH_HOME}/authorized_keys"
    [ -f "${SSH_HOME}/id_rsa" ] && chmod 600 "${SSH_HOME}/id_rsa"
    [ -f "${SSH_HOME}/id_rsa.pub" ] && chmod 644 "${SSH_HOME}/id_rsa.pub"
fi

# The deployer runs without sudo, so APP_USER must own the sites directory
# to create sites in it. When the host directory of the bind mount doesn't
# exist, Docker creates it owned by root: only in that case hand it to
# APP_USER (the directory itself, not its contents, and keeping its group).
SITES_ROOT="${WWW_ROOT_PATH:-/var/www/sites}"
if [ -d "${SITES_ROOT}" ] && [ ! -L "${SITES_ROOT}" ] \
    && [ "$(stat -c %u "${SITES_ROOT}")" = "0" ]; then
    chown "${APP_USER}" "${SITES_ROOT}"
fi

# Show the current user.
echo "Current user: $(whoami)"

# Run the main process (by default supervisord).
exec "$@"
