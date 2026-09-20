#!/bin/bash

# Unified script to generate supervisord configuration from Procfile.
# Reads Procfile and generates a single supervisord configuration.
# Usage: ./start_procfile_supervisord.sh [site_name_optional]

set -e

# Function for logging messages.
log_info() {
    echo "$(date +'%Y-%m-%d %H:%M:%S') [INFO] - $1"
}

log_error() {
    echo "$(date +'%Y-%m-%d %H:%M:%S') [ERROR] - $1" >&2
}

log_warning() {
    echo "$(date +'%Y-%m-%d %H:%M:%S') [WARNING] - $1" >&2
}

# Configuration variables.
SUPERVISORD_DIR=${SUPERVISORD_DIR:-/etc/supervisor/conf.d}
BASE_SITES_DIR=${BASE_SITES_DIR:-/var/www/sites}
APP_USER=${APP_USER:-admin}
LOG_DIR="/var/log"

# Per-site Caddy path routes generated from CADDY_ROUTE_PATH (see
# configure_site()), imported by config/caddy/Caddyfile via a glob. Set to 1
# by configure_site() whenever a site's routes actually change, so Caddy is
# only validated/reloaded once, at the end, and only if something changed.
CADDY_ROUTES_DIR=${CADDY_ROUTES_DIR:-/etc/caddy/routes.d}
CADDY_NEEDS_RELOAD=0

# Validate that supervisord directories exist.
if [ ! -d "$SUPERVISORD_DIR" ]; then
    log_info "Creating supervisord configuration directory: $SUPERVISORD_DIR"
    mkdir -p $SUPERVISORD_DIR
else
    log_info "✓ Supervisord configuration directory exists: $SUPERVISORD_DIR"
fi

# Validate that the Caddy routes directory exists.
if [ ! -d "$CADDY_ROUTES_DIR" ]; then
    log_info "Creating Caddy routes directory: $CADDY_ROUTES_DIR"
    sudo mkdir -p "$CADDY_ROUTES_DIR"
else
    log_info "✓ Caddy routes directory exists: $CADDY_ROUTES_DIR"
fi

if [ ! -d "/var/log/supervisor" ]; then
    log_info "Creating supervisord logs directory: /var/log/supervisor"
    mkdir -p /var/log/supervisor
else
    log_info "✓ Supervisord logs directory exists: /var/log/supervisor"
fi

# Function to automatically detect Django project.
detect_django_project() {
    local current_path="$1"

    # Search for wsgi.py in current directory.
    local wsgi_path=$(find "$current_path/" -maxdepth 2 -name wsgi.py | head -n 1)

    if [ -z "$wsgi_path" ]; then
        log_error "Could not find wsgi.py file in $current_path/"
        return 1
    fi

    # Extract project name.
    local project_dir=$(dirname "$wsgi_path")
    local django_project=$(basename "$project_dir")

    log_info "Found wsgi.py at $wsgi_path, project: $django_project"
    echo "$django_project"
}

# Function to process a specific site.
configure_site() {
    local site_path="$1"
    local site_name=$(basename "$site_path")

    log_info "Processing site: $site_name"

    # Build paths as in original code.
    local current_path="$site_path/current"
    local venv_path="venv"
    local procfile="$current_path/Procfile"

    log_info "Base path: $site_path"
    log_info "Current path: $current_path"
    log_info "Procfile: $procfile"

    # Check if current directory exists.
    if [ ! -d "$current_path" ]; then
        log_error "Directory '$current_path' not found for site $site_name"
        return 1
    fi

    # Check if Procfile exists.
    if [ ! -f "$procfile" ]; then
        log_warning "No Procfile found for $site_name, skipping"
        return 1
    fi

    # Detect Django project.
    local django_project=$(detect_django_project "$current_path")
    if [ $? -ne 0 ]; then
        return 1
    fi

    # Paths to executables.
    local gunicorn_bin="$current_path/$venv_path/bin/gunicorn"
    local celery_bin="$current_path/$venv_path/bin/celery"

    # Verify binaries exist.
    if [ ! -f "$gunicorn_bin" ]; then
        log_error "Gunicorn binary not found at '$gunicorn_bin' for site $site_name"
        return 1
    fi

    if [ ! -f "$celery_bin" ]; then
        log_error "Celery binary not found at '$celery_bin' for site $site_name"
        return 1
    fi

    # Create necessary directories.
    if [ ! -d "/run/gunicorn" ]; then
        log_error "Directory '/run/gunicorn' does not exist. Please create it with appropriate permissions."
        return 1
    fi

    if [ ! -d "$LOG_DIR/gunicorn" ]; then
        log_info "Creating gunicorn logs directory: $LOG_DIR/gunicorn"
        mkdir -p "$LOG_DIR/gunicorn"
    fi

    if [ ! -d "$LOG_DIR/celery" ]; then
        log_info "Creating celery logs directory: $LOG_DIR/celery"
        mkdir -p "$LOG_DIR/celery"
    fi

    log_info "=== Configuring services for $site_name ==="
    log_info "Django project: $django_project"
    log_info "Gunicorn binary: $gunicorn_bin"
    log_info "Celery binary: $celery_bin"

    # Generate supervisord configuration (one file per site).
    local config_file="/tmp/django-supervisord-$site_name.conf"
    local final_config_file="$SUPERVISORD_DIR/django-supervisord-$site_name.conf"

    # Initialize configuration file.
    cat > "$config_file" << EOF
; Supervisord configuration for $site_name
; Auto-generated from Procfile
; Date: $(date)

EOF

    # Per-site Caddy path routes (see CADDY_ROUTE_PATH handling below).
    # caddy_routes_content accumulates one @matcher/handle block per route
    # declared in this site's Procfile; seen_route_paths catches two
    # processes of the same site declaring the same path (ambiguous: which
    # one should Caddy send it to?); site_has_route_error, once set, means
    # this site's Caddy routes are NOT written at the end — the previous
    # (working) file, if any, is left untouched rather than replaced with
    # something ambiguous.
    local caddy_routes_content=""
    local -A seen_route_paths=()
    local site_has_route_error=0

    # Read and process each line from Procfile.
    while IFS= read -r line; do
        # Skip empty lines and comments.
        if [[ -z "$line" || "$line" =~ ^[[:space:]]*# ]]; then
            continue
        fi

        # Extract process name and command (preserve quotes).
        local process_name
        process_name=$(printf '%s' "$line" | cut -d: -f1)
        local command
        command=$(printf '%s' "$line" | cut -d: -f2-)
        # Left-trim spaces from command only (do not strip quotes).
        command="${command#${command%%[![:space:]]*}}"

        # CADDY_ROUTE_PATH=<path>, set inline like any other env var on a
        # Procfile command line, opts this process into its own gunicorn
        # socket and a Caddy rule routing that path (for this site only) to
        # it instead of the site's main "web" socket. Supervisord does not
        # go through a shell, so this token is extracted here and stripped
        # from the command — left in place, supervisord would try to exec
        # "CADDY_ROUTE_PATH=..." itself as the program.
        local route_path=""
        if [[ "$command" =~ CADDY_ROUTE_PATH=([^[:space:]]+) ]]; then
            route_path="${BASH_REMATCH[1]}"
            command=$(printf '%s' "$command" | sed -E 's/CADDY_ROUTE_PATH=[^[:space:]]+[[:space:]]*//')

            if [[ "$process_name" == "web" ]]; then
                log_error "CADDY_ROUTE_PATH no debe usarse en el proceso 'web' de $site_name (le quitaría su socket principal); use un nombre de proceso propio. Se ignora esta ruta."
                route_path=""
                site_has_route_error=1
            elif [[ -n "${seen_route_paths[$route_path]:-}" ]]; then
                log_error "CADDY_ROUTE_PATH duplicado ('$route_path') en $site_name, entre los procesos '${seen_route_paths[$route_path]}' y '$process_name': es ambiguo a cuál debe ir. No se actualiza el ruteo de Caddy de $site_name esta vez."
                site_has_route_error=1
            else
                seen_route_paths["$route_path"]="$process_name"

                local safe_process_name
                safe_process_name=$(printf '%s' "$process_name" | tr -c 'A-Za-z0-9_-' '_')
                local route_socket_path="/run/gunicorn/${site_name}--${safe_process_name}.sock"

                # Same substitution the "web" branch below does for its own
                # socket — reused here so a CADDY_ROUTE_PATH line is written
                # in the Procfile exactly like a normal "web"-style gunicorn
                # command (--bind :8000), never hardcoding a socket path.
                command=$(printf '%s' "$command" | sed "s|--bind :8000|--bind unix:$route_socket_path|")

                caddy_routes_content+=$'\n'"@${site_name}_${safe_process_name}_route expression \`{real_domain} == \"${site_name}\" && path(\"${route_path}\")\`"
                caddy_routes_content+=$'\n'"handle @${site_name}_${safe_process_name}_route {"
                caddy_routes_content+=$'\n'"	reverse_proxy unix/${route_socket_path} {"
                caddy_routes_content+=$'\n'"		header_up X-Forwarded-Host {domain_input}"
                caddy_routes_content+=$'\n'"	}"
                caddy_routes_content+=$'\n'"}"
                caddy_routes_content+=$'\n'
            fi
        fi

        log_info "Processing: $process_name -> $command"

        # Determine process type and configure accordingly.
        if [[ "$process_name" == "web" ]]; then
            # Configuration for Gunicorn.
            local socket_path="/run/gunicorn/$site_name.sock"
            local access_log="$LOG_DIR/gunicorn/$site_name-access.log"
            local error_log="$LOG_DIR/gunicorn/$site_name-error.log"

            # Replace bind :8000 with unix socket (preserve content).
            local gunicorn_cmd
            gunicorn_cmd=$(printf '%s' "$command" | sed "s|--bind :8000|--bind unix:$socket_path|")
            # Escape % so supervisord does not try to interpolate (e.g. %(h)s).
            local gunicorn_cmd_escaped=${gunicorn_cmd//%/%%}

            cat >> "$config_file" << EOF
[program:django-$site_name-web]
command=$gunicorn_cmd_escaped
directory=$current_path
user=$APP_USER
autostart=true
autorestart=true
redirect_stderr=true
stdout_logfile=/var/log/supervisor/gunicorn-$site_name.log
stdout_logfile_maxbytes=50MB
stdout_logfile_backups=10
stderr_logfile=/var/log/supervisor/gunicorn-$site_name-error.log
stderr_logfile_maxbytes=50MB
stderr_logfile_backups=10
environment=HOME="/home/$APP_USER",PATH="$current_path/$venv_path/bin:/usr/local/bin:/usr/bin:/bin",PYTHONPATH="$current_path"
priority=900
startsecs=10
startretries=3
stopwaitsecs=10
killasgroup=true
stopasgroup=true

EOF

        elif [[ "$process_name" =~ ^celery_worker ]]; then
            # Configuration for Celery Workers.
            local worker_log="$LOG_DIR/celery/$site_name-$process_name.log"
            # Escape % for supervisord.
            local command_escaped=${command//%/%%}

            cat >> "$config_file" << EOF
[program:django-$site_name-$process_name]
command=$command_escaped
directory=$current_path
user=$APP_USER
autostart=true
autorestart=true
redirect_stderr=true
stdout_logfile=/var/log/supervisor/celery-$site_name-$process_name.log
stdout_logfile_maxbytes=50MB
stdout_logfile_backups=10
environment=HOME="/home/$APP_USER",PATH="$current_path/$venv_path/bin:/usr/local/bin:/usr/bin:/bin",PYTHONPATH="$current_path"
priority=920
startsecs=10
startretries=3
stopwaitsecs=30
killasgroup=true
stopasgroup=true

EOF

        elif [[ "$process_name" == "celery_beat" ]]; then
            # Configuration for Celery Beat.
            local beat_log="$LOG_DIR/celery/$site_name-beat.log"
            # Escape % for supervisord.
            local command_escaped=${command//%/%%}

            cat >> "$config_file" << EOF
[program:django-$site_name-celery-beat]
command=$command_escaped
directory=$current_path
user=$APP_USER
autostart=true
autorestart=true
redirect_stderr=true
stdout_logfile=/var/log/supervisor/celery-$site_name-beat.log
stdout_logfile_maxbytes=50MB
stdout_logfile_backups=10
environment=HOME="/home/$APP_USER",PATH="$current_path/$venv_path/bin:/usr/local/bin:/usr/bin:/bin",PYTHONPATH="$current_path"
priority=910
startsecs=10
startretries=3
stopwaitsecs=30
killasgroup=true
stopasgroup=true

EOF

        else
            # Generic configuration for other processes.
            log_warning "Unrecognized process type: $process_name, using generic configuration"
            # Escape % for supervisord.
            local command_escaped=${command//%/%%}

            cat >> "$config_file" << EOF
[program:django-$site_name-$process_name]
command=$command_escaped
directory=$current_path
user=$APP_USER
autostart=true
autorestart=true
redirect_stderr=true
stdout_logfile=/var/log/supervisor/$site_name-$process_name.log
stdout_logfile_maxbytes=50MB
stdout_logfile_backups=10
environment=HOME="/home/$APP_USER",PATH="$current_path/$venv_path/bin:/usr/local/bin:/usr/bin:/bin",PYTHONPATH="$current_path"
priority=950
startsecs=10
startretries=3
stopwaitsecs=30
killasgroup=true
stopasgroup=true

EOF
        fi

    done < "$procfile"


    # Move temporary file to final directory with sudo.
    log_info "Moving configuration to $final_config_file..."
    if sudo mv "$config_file" "$final_config_file"; then
        log_info "✓ Configuration created: $final_config_file"
    else
        log_error "Error moving configuration to $final_config_file"
        return 1
    fi

    # Write (or remove) this site's Caddy routes file. Regenerated in full
    # from the current Procfile every time, so a CADDY_ROUTE_PATH line
    # removed from it makes its route disappear here too — no leftover
    # rules for routes that no longer exist.
    local caddy_route_file="$CADDY_ROUTES_DIR/$site_name.conf"
    if [ "$site_has_route_error" = "1" ]; then
        log_error "$site_name tiene CADDY_ROUTE_PATH ambiguos (ver arriba): se deja el ruteo de Caddy de $site_name como estaba, sin aplicar los cambios de esta corrida."
    elif [ -n "$caddy_routes_content" ]; then
        local caddy_tmp="/tmp/caddy-routes-$site_name.conf"
        {
            echo "# Caddy routes for site: $site_name"
            echo "# Auto-generated from its Procfile (CADDY_ROUTE_PATH) — do not edit by hand."
            echo "# Date: $(date)"
            echo "$caddy_routes_content"
        } > "$caddy_tmp"

        if sudo mv "$caddy_tmp" "$caddy_route_file"; then
            log_info "✓ Rutas de Caddy actualizadas para $site_name: $caddy_route_file"
            CADDY_NEEDS_RELOAD=1
        else
            log_error "No se pudo mover el archivo de rutas de Caddy para $site_name"
        fi
    elif [ -f "$caddy_route_file" ]; then
        sudo rm -f "$caddy_route_file"
        log_info "Sin CADDY_ROUTE_PATH en $site_name: se eliminaron sus rutas de Caddy previas ($caddy_route_file)."
        CADDY_NEEDS_RELOAD=1
    fi
}

# Check parameters and process sites.
if [ -n "$1" ]; then
    # Specific site specified.
    SITE_NAME=$1
    site_path="$BASE_SITES_DIR/$SITE_NAME"

    log_info "Site specified: $SITE_NAME"

    if [ -d "$site_path" ]; then
        configure_site "$site_path"
    else
        log_error "The specified site '$site_path' does not exist."
        exit 1
    fi
else
    # Process all sites.
    log_info "Processing all sites in $BASE_SITES_DIR/*"

    # Check that base directory exists.
    if [ ! -d "$BASE_SITES_DIR" ]; then
        log_error "The directory '$BASE_SITES_DIR' does not exist."
        exit 1
    fi

    # Iterate over each site.
    for site_path in $BASE_SITES_DIR/*; do
        if [ -d "$site_path" ]; then
            configure_site "$site_path" || true  # Continue even if one fails.
        fi
    done
fi

# If supervisord is running, apply changes.
if command -v supervisorctl >/dev/null 2>&1 && pgrep supervisord >/dev/null; then
    log_info "Applying configuration to supervisord..."
    if sudo supervisorctl reread && sudo supervisorctl update; then
        log_info "Changes applied successfully"
        log_info "Service status:"
        sudo supervisorctl status | grep django-
    else
        log_error "Error applying changes to supervisord"
        log_info "Apply manually with:"
        log_info "sudo supervisorctl reread && sudo supervisorctl update"
    fi
else
    log_info "To apply configuration when supervisord is running:"
    log_info "sudo supervisorctl reread && sudo supervisorctl update"
fi

# If any site's CADDY_ROUTE_PATH routes changed, validate the whole Caddy
# config before reloading it — a broken/ambiguous site must not be able to
# take Caddy down for every other site sharing this container. On failure,
# the currently running Caddy process is left untouched (it keeps serving
# its last successfully loaded config; only a future restart of Caddy
# itself, not of this script, would pick up the bad on-disk file).
if [ "$CADDY_NEEDS_RELOAD" = "1" ]; then
    if command -v caddy >/dev/null 2>&1 && pgrep caddy >/dev/null; then
        log_info "Validando configuración de Caddy (rutas por sitio cambiaron)..."
        if sudo -E caddy validate --config /etc/caddy/Caddyfile --adapter caddyfile; then
            log_info "✓ Configuración de Caddy válida, recargando..."
            if sudo -E caddy reload --config /etc/caddy/Caddyfile --adapter caddyfile; then
                log_info "✓ Caddy recargado correctamente"
            else
                log_error "No se pudo recargar Caddy (la configuración anterior sigue activa)"
            fi
        else
            log_error "La configuración de Caddy generada NO es válida: no se recarga, sigue activa la anterior. Revise los archivos en $CADDY_ROUTES_DIR/"
        fi
    else
        log_info "Caddy no está corriendo; las rutas se aplicarán la próxima vez que arranque."
    fi
fi

log_info "=== Process completed ==="
log_info "Configurations created in: $SUPERVISORD_DIR/"
log_info "Logs available in: /var/log/supervisor/, $LOG_DIR/gunicorn/ and $LOG_DIR/celery/"
