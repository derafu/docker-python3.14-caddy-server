# Derafu Sites Server - Docker with Python and Caddy for Fabric

![GitHub last commit](https://img.shields.io/github/last-commit/derafu/docker-python3.14-caddy-server/main)
![GitHub code size in bytes](https://img.shields.io/github/languages/code-size/derafu/docker-python3.14-caddy-server)
![GitHub Issues](https://img.shields.io/github/issues-raw/derafu/docker-python3.14-caddy-server)

A modern Docker setup for hosting Python websites with Caddy web server and SSH access for Fabric deployments.

## Features

- **Python 3.14.7**: Supported Python version with common extensions.
- **Caddy**: Modern web server with automatic HTTPS.
- **SSH Access**: For automated deployments with Fabric.
- **Automatic Site Discovery**: Just add your site folder and it works.
- **Development Domains**: Test with .local domains that map to production folders.
- **Automatic WWW Redirection**: For second-level domains (e.g., example.com → www.example.com).
- **Auto-HTTPS**: Certificates are automatically generated on-demand.
- **Environment Separation**: Development and production environments managed through Docker Compose override.
- **Optional PHP embed + phpy**: Build PHP with `--enable-embed` and install [phpy](https://github.com/swoole/phpy)
  so Python code running in this container can host and call PHP libraries directly
  (e.g. `derafu/backbone-bridge-python`). Disabled by default; see
  [PHP embed + phpy (optional)](#php-embed--phpy-optional) below.

## Quick Start

### Prerequisites

- Docker and Docker Compose installed on your system.
- SSH key for deployment access.

### Setup

1. Clone this repository:
   ```bash
   git clone https://github.com/derafu/docker-python3.14-caddy-server.git
   cd docker-python3.14-caddy-server
   ```

2. Copy the environment and override templates (both are gitignored, so a
   fresh clone starts without them):
   ```bash
   cp .env-dist .env
   cp docker-compose.override-example.yml docker-compose.override.yml
   ```
   `docker-compose.override.yml` is where the HTTP/HTTPS/SSH ports are
   actually mapped to the host — without it, `docker-compose up -d` starts
   the container with no ports exposed at all.

3. Add your SSH public key to `config/ssh/authorized_keys` for admin, and default deployment, access:
   ```bash
   cat ~/.ssh/id_rsa.pub > config/ssh/authorized_keys
   ```
   No SSH keys are baked into the image: `docker-compose.override.yml` mounts
   `config/ssh/` (or `VOLUME_SSH`) at `/home/admin/.ssh`, and the entrypoint
   fixes its ownership and permissions on every start. If you change the keys
   while the container is running, restart it.

4. Build and start the container:
   ```bash
   docker-compose up -d
   ```
   The `-d` parameter runs it in detached mode (background).

### Verification

Check that the container is running:

```bash
docker-compose ps
```

View container logs:

```bash
docker-compose logs -f
```

The `-f` parameter allows you to follow logs in real-time.

### Testing Your First Site

1. Create the site directory structure:
   ```bash
   mkdir -p sites/www.example.com/
   cd sites/www.example.com/
   ```

2. Create project Django
   ```bash
   python3 -m venv venv
   source venv/bin/activate
   pip install django
   django-admin startproject example .
   ```

3. Run a single site manually
   ```bash
   docker-compose exec webserver /scripts/start_procfile_supervisord.sh www.example.com
   ```
   Note: If no site is specified, the script will start all available sites under /var/www/sites.

4. Access the site at:
   - Production mode: https://www.example.com (requires DNS configuration).
   - Development mode: https://www.example.com.local:8443 (requires local hosts entry).

For local development, add to your `/etc/hosts` file:
```
127.0.0.1 www.example.com.local
```

## PHP embed + phpy (optional)

This image can optionally build PHP from source with `--enable-embed` and install
[phpy](https://github.com/swoole/phpy), so Python code can load and call a PHP
library directly in the same process (the Python-hosts-PHP direction; the
opposite direction, PHP-hosts-Python, is what `docker-php8.5-caddy-server` provides).

This is **disabled by default**: no regular PHP package (apt, homebrew, official
Docker images) ships with `--enable-embed`, so getting it requires compiling PHP
from source, which adds several minutes to the image build. Enable it explicitly
when you actually need it:

```bash
# In your .env file:
PHPY_ENABLED=true
PHPY_PHP_VERSION=8.5.12   # optional, defaults to 8.5.12
# If you change the PHP version, also set PHPY_PHP_SHA256 (php.net/releases).

docker compose build
docker compose up -d
```

When enabled, the embed-enabled PHP build lives at `/opt/php` (`php`, `php-config`,
`phpize`, `composer` on `PATH`), and `phpy` is installed into the container's Python.
Verify it works with:

```bash
docker compose exec webserver python3 -c "import phpy; print(phpy)"
```

Building with the default `PHPY_ENABLED=false` skips all of this and behaves
exactly like a normal Python + Caddy image.

## Directory Structure

```
docker-python3.14-caddy-server/
├── Dockerfile                  # Python + Caddy server base image definition (+ optional PHP/phpy)
├── entrypoint.sh               # Runs on every start: shell env file, ~/.ssh and sites dir permissions
├── docker-compose.yml          # Production Docker services and volumes
├── docker-compose.override-example.yml  # Template: copy to docker-compose.override.yml
├── .env-dist                   # Template: copy to .env
├── .env                        # Environment variables for docker-compose (gitignored)
├── LICENSE                     # Project license
├── README.md                   # Main project documentation
Configuration
├── config/
│   ├── bash/
│   │   └── bashrc              # Shell prompt / history tweaks for container user
│   ├── caddy/
│   │   ├── Caddyfile           # Caddy reverse proxy rules (HTTPS, domains, routing)
│   │   └── routes.d/           # Per-site path routes, generated from CADDY_ROUTE_PATH
│   ├── cron/
│   │   └── logrotate           # Cron job for rotating logs periodically
│   ├── logrotate/
│   │   ├── caddy               # Logrotate rules for Caddy
│   │   └── gunicorn             # Logrotate rules for Gunicorn
│   ├── ssh/
│   │   ├── authorized_keys     # Public keys for SSH login (mounted at runtime, gitignored)
│   │   └── sshd_config         # SSH server settings (OpenSSH)
│   └── supervisor/
│       └── supervisord.conf    # Supervisor config to manage processes (Caddy, Gunicorn, etc.)
Development
├── sites/                      # Django projects, one per domain
│   └── www.example.com/        # Project folder for www.example.com
Helper Scripts
├── scripts/
│   └── start_procfile_supervisord.sh   # Auto-detect and launch Gunicorn/Celery for each site under /sites
Documentation
├── docs/
│   └── docker.md                # Notes and recommendations for Docker usage
CI
├── .github/
│   ├── ci/
│   │   ├── test-image.sh       # End-to-end test of a built image (also runnable locally)
│   │   └── django-site/        # Minimal Django site served by that test
│   └── workflows/              # Test on pushes and pull requests; test before publishing images
```

## Development vs Production Environment

This project uses Docker Compose's override functionality to separate development and production configurations:

### Production Environment

The base `docker-compose.yml` contains the minimal configuration needed for production deployment. It:

- Sets up required environment variables.
- Defines essential ports (HTTP, HTTPS, SSH).
- Doesn't mount external volumes.

### Development Environment

The `docker-compose.override.yml` file adds development-specific settings:

- Adds additional development ports (e.g., management interface).
- Mounts local volumes for easy site development.

### Usage:

- **Development**: Docker Compose automatically merges both files:
  ```bash
  docker-compose up -d
  ```

- **Production**: Use only the base configuration:
  ```bash
  docker-compose -f docker-compose.yml up -d
  ```

## Access and Management

### SSH Access

Connect to the container via SSH:

```bash
ssh admin@localhost -p 2222
```

### Direct Container Access

Access the container shell:

```bash
docker-compose exec webserver bash
```

### Restarting Services

Restart Caddy web server:

```bash
docker-compose exec webserver supervisorctl restart caddy
```

### Stopping the Container

```bash
docker-compose down
```

### Rebuilding After Configuration Changes

Rebuild for development:

```bash
docker-compose build --no-cache
docker-compose up -d
```

Rebuild for production:

```bash
docker-compose -f docker-compose.yml build --no-cache
docker-compose -f docker-compose.yml up -d
```

## Adding New Sites

1. Create the site directory structure:
   ```bash
   mkdir -p sites/www.newsite.com/
   cd sites/www.newsite.com/
   ```

2. Create project Django
   ```bash
   python3 -m venv venv
   source venv/bin/activate
   pip install django
   django-admin startproject newsite .
   ```
   NOTE: It's important that the requirements.txt file includes the gunicorn dependency (Example gunicorn==23.0.0)

3. Start the site's processes (Caddy itself needs no restart — it detects
   new sites automatically on the next request — but its gunicorn process
   does need to be registered with supervisor at least once):
   ```bash
   docker-compose exec webserver /scripts/start_procfile_supervisord.sh www.newsite.com
   ```

4. For local development, add to your hosts file:
   ```
   127.0.0.1 www.newsite.com.local
   ```

## Environment Variables

Customize behavior through environment variables:

| Variable                     | Description                       | Default             |
|------------------------------|-----------------------------------|---------------------|
| `SERVER_NAME`                | Name for the docker container     | derafu-sites-server-python-caddy |
| `CADDY_DEBUG`                | Enable debug mode with `debug`    | (empty)             |
| `CADDY_EMAIL`                | Email for Let's Encrypt           | admin@example.com   |
| `CADDY_HTTPS_ISSUER`         | TLS issuer (internal, acme)       | internal            |
| `CADDY_HTTPS_ALLOW_ANY_HOST` | Allow any host for TLS            | false               |
| `CADDY_LOG_SIZE`             | Log file max size                 | 100mb               |
| `CADDY_LOG_KEEP`             | Number of log files to keep       | 5                   |
| `WWW_ROOT_PATH`              | Web root path                     | /var/www/sites      |
| `WWW_USER`                   | WWW and SSH user in the container | admin               |
| `WWW_GROUP`                  | WWW group in the container        | www-data            |
| `HTTP_PORT`                  | HTTP port in host                 | 8080                |
| `HTTPS_PORT`                 | HTTPS port in host                | 8443                |
| `SSH_PORT`                   | SSH port in host                  | 2222                |
| `MANAGER_PORT`               | Port for the on-demand TLS endpoint (`/api/ask`) | 9090 |
| `VOLUME_SSH`                 | Host directory mounted at `/home/admin/.ssh` (override) | ./config/ssh |
| `NETWORK_TOOLS_ENABLE`       | Install `nmap` and `socat` at build time (`1`) | 0 |
| `DEPLOYER_HOST`              | **No effect yet.** Not passed into the container by `docker-compose.yml`; expects `derafu/python-fabric-deployer` (external tooling) | (empty) |
| `PHPY_ENABLED`               | Build PHP (`--enable-embed`) + phpy + Composer | false             |
| `PHPY_PHP_VERSION`           | PHP version to build when `PHPY_ENABLED=true` | 8.5.12    |
| `PHPY_PHP_SHA256`            | SHA-256 of that PHP release tarball (checked at build); must match `PHPY_PHP_VERSION` | (that of 8.5.12) |
| `PHPY_REF`                   | phpy commit to build | `6629eec` |

## Domain Logic

The server handles domains in the following way:

1. **Development domains**: Any domain ending with `.local` (e.g., `www.example.com.local`)
   - Maps to the same directory as its production counterpart.
   - Uses internal self-signed certificates.

2. **Production domains**:
   - Redirects from non-www to www for second-level domains.
   - Automatically obtains and manages Let's Encrypt certificates (issuer `acme`).

## Troubleshooting

### SSL Certificate Issues

If you're having issues with SSL certificates in development:

- Ensure your browser trusts self-signed certificates.
- Try using HTTP instead of HTTPS for local development.

### Permissions Issues

If you encounter permission issues:

```bash
docker-compose exec webserver chown -R admin:www-data /var/www/sites
```

### Logs Location

Logs are available in the container and can be accessed with:

```bash
docker-compose exec webserver cat /var/log/caddy/access.log
```

## Security Notes

- `admin` has no general `sudo`: the only command it can run as root is
  `/scripts/start_procfile_supervisord.sh` (it re-runs itself through sudo
  when started as `admin`). Its password is `*`, so SSH public key login
  works but `su`/`sudo` never accept a password. For root, use
  `docker-compose exec -u 0 webserver bash` from the host.
- Restart services from the host (see [Restarting Services](#restarting-services)):
  `admin` cannot use `supervisorctl`.
- The deployer runs without sudo, so `admin` (uid 1000) must own the host
  directory mounted at `/var/www/sites`. On Linux, if Docker creates that
  directory (owned by root), the entrypoint hands it to `admin` on start; any
  other owner is left as is.
- `nmap` and `socat` are not installed unless built with
  `NETWORK_TOOLS_ENABLE=1`.
- Caddy runs as root and follows symlinks under each site's `static/` and
  `media/`, so whoever controls a site's files can publish any file readable
  by root. Keep that in mind when giving access to `admin`.

## Advanced Usage

### Custom Caddy Configuration

For advanced configurations, modify the Caddyfile at `config/caddy/Caddyfile`.

### Routing one path to a dedicated process (`CADDY_ROUTE_PATH`)

A site's `Procfile` normally has one `web:` process handling every
request. Sometimes a specific URL path needs its own, differently
configured process instead — for example, an endpoint that must run
single-threaded (`--worker-class sync`) while the rest of the site keeps
`gthread`, to isolate it without affecting anything else the site serves.

Add a `CADDY_ROUTE_PATH=<path>` environment variable inline on that
process's own `Procfile` line (this is plain shell syntax — any process
manager that reads a `Procfile` understands it, nothing custom):

```
web: gunicorn --bind :8000 --workers 4 --threads 4 --worker-class gthread yourproject.wsgi:application
heavy: CADDY_ROUTE_PATH=/api/v2/heavy/* gunicorn --bind :8000 --workers 2 --worker-class sync --timeout 300 yourproject.wsgi:application
```

- The process name (`heavy` above) can be anything except `web`.
- Write `--bind :8000` like any other process — it gets rewritten to that
  process's own private socket automatically, the same way `web:` already
  works. Never hardcode a socket path yourself.
- `<path>` is a Caddy path pattern (glob), e.g. `/api/v2/heavy/*`.

Apply it by (re-)running the site's setup script:

```bash
docker-compose exec webserver /scripts/start_procfile_supervisord.sh yoursite.com
```

This generates the matching Caddy rule under `config/caddy/routes.d/`,
validates the *entire* Caddy configuration, and reloads Caddy only if it's
valid — a broken or ambiguous route (e.g. two processes on the same site
declaring the same path) is rejected, logged, and the previous, working
routing is kept untouched, for that site and every other one sharing the
container. Everything else on the site keeps going to its normal `web:`
process, unaffected.

---

## Contributing

Contributions are welcome! Please feel free to submit a Pull Request. For major changes, please open an issue first to discuss what you would like to change.

Pushes to any branch and pull requests run the image test
(`.github/workflows/test-image.yml`). On `main` it runs before publishing,
and images are only published if it passes. Run it locally against a built image
with:

```bash
.github/ci/test-image.sh <image> [true]   # "true" also tests PHP embed + phpy
```

## License

This package is open-sourced software licensed under the [MIT license](https://opensource.org/licenses/MIT).
