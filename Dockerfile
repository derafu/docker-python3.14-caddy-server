# Use Python 3.14.7 as base.
FROM python:3.14.7

# Arguments.
ARG CADDY_DEBUG=
ARG WWW_ROOT_PATH=/var/www/sites
ARG WWW_USER=admin
ARG WWW_GROUP=www-data

# Optional: build PHP with --enable-embed and install phpy (Python -> PHP
# bridge, https://github.com/swoole/phpy) so this image can host PHP code
# from Python (e.g. derafu/backbone-bridge-python). Disabled by default to
# keep the default build fast and unchanged; enable with:
#   PHPY_ENABLED=true docker compose build
# (wired through docker-compose.yml -> this ARG).
ARG PHPY_ENABLED=false
ARG PHPY_PHP_VERSION=8.5.3

# Expose ports.
EXPOSE 22 80 443 9090 8000

# Run a lot of commands :)
RUN \
    \
    # Install basic dependencies.
    apt-get update && apt-get install -y --no-install-recommends \
    apt-transport-https \
    at \
    ca-certificates \
    build-essential \
    cargo \
    cron \
    curl \
    cython3 \
    debian-archive-keyring \
    debian-keyring \
    gnupg \
    g++ \
    gcc \
    gir1.2-gdkpixbuf-2.0 \
    git \
    iputils-ping \
    libgd-dev \
    libicu-dev \
    libsqlite3-dev \
    libzip-dev \
    lsb-release \
    libcairo2 \
    libblas-dev \
    libffi-dev \
    libfreetype6-dev \
    libfribidi-dev \
    libgdk-pixbuf-2.0-dev \
    libgfortran5 \
    libharfbuzz-dev \
    libjpeg-dev \
    liblapack-dev \
    libnss3-tools \
    libopenblas-dev \
    libpango1.0-dev \
    libpq-dev \
    libxml2-dev \
    libxslt-dev \
    logrotate \
    locales \
    meson \
    nano \
    nmap \
    net-tools \
    ninja-build \
    openssh-client \
    openssh-server \
    postgresql-client \
    rustc \
    shared-mime-info \
    socat \
    screen \
    sudo \
    supervisor \
    unzip \
    vim \
    wget \
    yq \
    zip \
    zlib1g-dev \
    # Install wkhtmltopdf.
    && ARCH=$(dpkg --print-architecture) \
    && if [ "$ARCH" = "arm64" ]; then \
        wget https://github.com/wkhtmltopdf/packaging/releases/download/0.12.6.1-3/wkhtmltox_0.12.6.1-3.bookworm_arm64.deb -O wkhtmltox.deb; \
    else \
        wget https://github.com/wkhtmltopdf/packaging/releases/download/0.12.6.1-3/wkhtmltox_0.12.6.1-3.bookworm_amd64.deb -O wkhtmltox.deb; \
    fi \
    && apt-get install -y ./wkhtmltox.deb \
    && rm wkhtmltox.deb \
    \
    # Install locales.
    && sed -i 's/# es_ES.UTF-8 UTF-8/es_ES.UTF-8 UTF-8/' /etc/locale.gen \
    && echo "es_CL.UTF-8 UTF-8" >> /etc/locale.gen \
    && echo "es_ES.UTF-8 UTF-8" >> /etc/locale.gen \
    && echo "es_CL ISO-8859-1" >> /etc/locale.gen \
    && echo "es_ES ISO-8859-1" >> /etc/locale.gen \
    && locale-gen \
    && update-locale LANG=es_CL.UTF-8 \
    \
    # Install Caddy.
    && curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/gpg.key' | gpg --dearmor -o /usr/share/keyrings/caddy-stable-archive-keyring.gpg \
    && curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/debian.deb.txt' | tee /etc/apt/sources.list.d/caddy-stable.list \
    && apt-get update \
    && apt-get install -y --no-install-recommends caddy \
    # Playwright/Chromium runtime libs for Debian Trixie (python:3.14).
    # Playwright 1.52 does not know Trixie and `install-deps` falls back to
    # Ubuntu 20.04 packages that do not exist here; install the Trixie
    # equivalents so host validation passes without that step.
    && apt-get install -y --no-install-recommends \
    fonts-liberation \
    fonts-unifont \
    libasound2 \
    libatk-bridge2.0-0 \
    libatk1.0-0 \
    libatspi2.0-0 \
    libcups2 \
    libdbus-1-3 \
    libdrm2 \
    libgbm1 \
    libgdk-pixbuf-2.0-0 \
    libgtk-3-0 \
    libnspr4 \
    libnss3 \
    libpango-1.0-0 \
    libx11-6 \
    libx11-xcb1 \
    libxcb1 \
    libxcomposite1 \
    libxcursor1 \
    libxdamage1 \
    libxext6 \
    libxfixes3 \
    libxi6 \
    libxkbcommon0 \
    libxrandr2 \
    libxrender1 \
    libxshmfence1 \
    && rm -rf /var/lib/apt/lists/* \
    \
    # Create SSH directory.
    && mkdir -p /var/run/sshd \
    \
    # Create admin user for SSH access.
    && useradd -m -d /home/${WWW_USER} -s /bin/bash ${WWW_USER} \
    && usermod -p '*' ${WWW_USER} \
    && echo "${WWW_USER} ALL=(ALL) NOPASSWD: ALL" >> /etc/sudoers \
    && chmod 0440 /etc/sudoers \
    && chmod g+w /etc/passwd \
    && mkdir -p /home/${WWW_USER}/.ssh \
    && chmod 700 /home/${WWW_USER}/.ssh \
    && ssh-keyscan -t rsa github.com >> /home/${WWW_USER}/.ssh/known_hosts \
    && chmod 600 /home/${WWW_USER}/.ssh/known_hosts \
    && chown ${WWW_USER}: /home/${WWW_USER}/.ssh/known_hosts \
    \
    # Create necessary directories for web content and give admin user access.
    && mkdir -p ${WWW_ROOT_PATH} \
    && chown -R ${WWW_USER}:${WWW_GROUP} ${WWW_ROOT_PATH} \
    && chmod 770 ${WWW_ROOT_PATH} -R \
    && ln -s ${WWW_ROOT_PATH} /home/${WWW_USER}/sites \
    \
    # Allow www-data and ${WWW_USER} users to add jobs to the at queue.
    && echo "www-data" >> /etc/at.allow \
    && echo "${WWW_USER}" >> /etc/at.allow \
    \
    # Add SSH known hosts.
    && mkdir -p /etc/ssh \
    && ssh-keyscan github.com >> /etc/ssh/ssh_known_hosts \
    && chmod 644 /etc/ssh/ssh_known_hosts

# Optional: build PHP (--enable-embed), phpy, and Composer, so Python can host
# PHP libraries (e.g. derafu/backbone-bridge-python + LibreDTE dispatcher).
# Skipped entirely unless PHPY_ENABLED=true.
RUN if [ "$PHPY_ENABLED" = "true" ]; then \
        echo "PHPY_ENABLED=true: building PHP ${PHPY_PHP_VERSION} with --enable-embed, phpy and Composer..." \
        && apt-get update && apt-get install -y --no-install-recommends \
            pkg-config \
            autoconf \
            bison \
            re2c \
            libssl-dev \
            libcurl4-openssl-dev \
            libonig-dev \
        && rm -rf /var/lib/apt/lists/* \
        && curl -fsSL "https://www.php.net/distributions/php-${PHPY_PHP_VERSION}.tar.gz" -o /tmp/php.tar.gz \
        && mkdir -p /usr/src/php \
        && tar -xzf /tmp/php.tar.gz -C /usr/src/php --strip-components=1 \
        && rm /tmp/php.tar.gz \
        && cd /usr/src/php \
        && ./configure \
            --prefix=/opt/php \
            --enable-embed=shared \
            --with-openssl \
            --with-curl \
            --enable-mbstring \
            --enable-soap \
            --enable-intl \
            --enable-bcmath \
            --enable-gd \
            --with-freetype \
            --with-jpeg \
            --with-zip \
            --with-zlib \
            --disable-cgi \
            --disable-phpdbg \
        && make -j"$(nproc)" \
        && make install \
        && cd / && rm -rf /usr/src/php \
        # PHP detects stack overflows against the stack of the main thread,
        # so calling it from another one -as phpy does when it is embedded
        # in a web application- aborts the first function it runs. Only -1
        # avoids it: the problem is not the limit but what it measures from.
        && mkdir -p /opt/php/lib \
        && printf 'zend.max_allowed_stack_size=-1\n' > /opt/php/lib/php.ini \
        && git clone https://github.com/swoole/phpy.git /opt/phpy \
        && cd /opt/phpy \
        && PHP_CONFIG=/opt/php/bin/php-config pip install --break-system-packages . \
        && cd / && rm -rf /opt/phpy \
        && curl -sS https://getcomposer.org/installer \
            | /opt/php/bin/php -- --install-dir=/opt/php/bin --filename=composer \
    ; else \
        echo "PHPY_ENABLED=false: skipping PHP/phpy build."; \
    fi

# Make the embed-enabled PHP CLI/php-config available on PATH when phpy is
# enabled (harmless no-op otherwise, the directory simply won't exist).
ENV PATH="/opt/php/bin:${PATH}"

# Configure SSH client (this will include the config form the server, but is not used for SSH access).
COPY config/ssh/ /home/${WWW_USER}/.ssh/
RUN chown -R ${WWW_USER}:${WWW_USER} /home/${WWW_USER}/.ssh \
    # Add SSH key for www-data user.
    && mkdir -p /var/www/.ssh \
    && ssh-keygen -t rsa -b 4096 -N "" -C "www-data@localhost" -f /var/www/.ssh/id_rsa -q \
    && cat /var/www/.ssh/id_rsa.pub >> /home/${WWW_USER}/.ssh/authorized_keys \
    && chown -R www-data:www-data /var/www/.ssh \
    && chmod 700 /var/www/.ssh \
    && chmod 600 /var/www/.ssh/id_rsa \
    # Set correct permissions for authorized_keys and id_rsa.
    && chmod 600 /home/${WWW_USER}/.ssh/authorized_keys || true \
    && [ -f /home/${WWW_USER}/.ssh/id_rsa ] && chmod 600 /home/${WWW_USER}/.ssh/id_rsa || true

# Add configuration to .bashrc of the user.
COPY config/bash/bashrc /root/add-to-bashrc
RUN cat /root/add-to-bashrc >> /home/${WWW_USER}/.bashrc \
    && rm -f /root/add-to-bashrc

# Configure Caddy.
COPY config/caddy/Caddyfile /etc/caddy/Caddyfile

# Configure SSH.
COPY config/ssh/sshd_config /etc/ssh/sshd_config

# Create log directories for Gunicorn and Caddy and Celery.
# Create directories with more restrictive permissions.
RUN mkdir -p /var/log/gunicorn /var/log/caddy /var/log/celery \
    && chown ${WWW_USER}:${WWW_GROUP} /var/log/gunicorn \
    && chown ${WWW_USER}:${WWW_GROUP} /var/log/caddy \
    && chown ${WWW_USER}:${WWW_GROUP} /var/log/celery \
    && chmod 755 /var/log/gunicorn /var/log/caddy /var/log/celery

# Copy logrotate configuration.
COPY config/logrotate/gunicorn /etc/logrotate.d/gunicorn
COPY config/logrotate/caddy /etc/logrotate.d/caddy
COPY config/logrotate/celery /etc/logrotate.d/celery

# Copy Cron configuration.
COPY config/cron/logrotate /etc/cron.d/logrotate

# Copy Supervisor configuration.
COPY config/supervisor/supervisord.conf /etc/supervisor/supervisord.conf

# Copy scripts.

COPY scripts/start_procfile_supervisord.sh /scripts/start_procfile_supervisord.sh
RUN chmod +x /scripts/start_procfile_supervisord.sh

RUN mkdir -p /run/gunicorn && chmod 777 /run/gunicorn

# Use Supervisor as the main process.
CMD ["/usr/bin/supervisord", "-c", "/etc/supervisor/supervisord.conf"]
