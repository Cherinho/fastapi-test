#!/usr/bin/env bash
set -Eeuo pipefail

APP_DIR="/opt/ghost-blog"

if [[ "$(id -u)" -ne 0 ]]; then
  echo "Error: install.sh must run as root." >&2
  exit 1
fi

install -d -m 0755 "$APP_DIR"
cd "$APP_DIR"

if [[ -f /opt/ghost-blog/docker-compose.yml ]]; then
  echo "Using supplied Docker Compose configuration."
elif [[ -f docker-compose.yml ]]; then
  echo "Using existing Docker Compose configuration."
else
  cat >docker-compose.yml <<'EOF'
services:
  mysql:
    image: mysql:8.0
    container_name: ghost-mysql
    restart: unless-stopped
    environment:
      MYSQL_DATABASE: ghost
      MYSQL_USER: ghost
      MYSQL_PASSWORD: ghost-demo-password-change-me
      MYSQL_ROOT_PASSWORD: ghost-demo-root-password-change-me
    volumes:
      - mysql-data:/var/lib/mysql
    networks:
      - ghost-internal
    healthcheck:
      test: ["CMD-SHELL", "mysqladmin ping -h 127.0.0.1 -u root -p$$MYSQL_ROOT_PASSWORD --silent"]
      interval: 10s
      timeout: 5s
      retries: 12
      start_period: 30s
  ghost:
    image: ghost:5-alpine
    container_name: ghost-app
    restart: unless-stopped
    depends_on:
      mysql:
        condition: service_healthy
    ports:
      - "127.0.0.1:2368:2368"
    environment:
      url: http://localhost:2368
      database__client: mysql
      database__connection__host: mysql
      database__connection__port: 3306
      database__connection__user: ghost
      database__connection__password: ghost-demo-password-change-me
      database__connection__database: ghost
    volumes:
      - ghost-content:/var/lib/ghost/content
    networks:
      - ghost-internal
    healthcheck:
      test: ["CMD-SHELL", "node -e \"require('http').get('http://127.0.0.1:2368',r=>process.exit(r.statusCode<500?0:1)).on('error',()=>process.exit(1))\""]
      interval: 15s
      timeout: 5s
      retries: 12
      start_period: 30s
volumes:
  mysql-data:
  ghost-content:
networks:
  ghost-internal:
    internal: true
EOF
fi

dnf -y update
dnf -y install docker

systemctl enable --now docker

if ! docker compose version >/dev/null 2>&1; then
  dnf -y install docker-compose-plugin
fi

systemctl enable docker

install -d -m 0644 /etc/systemd/system
cat >/etc/systemd/system/ghost-blog.service <<EOF
[Unit]
Description=Ghost Blog Docker Compose application
Requires=docker.service
After=docker.service network-online.target
Wants=network-online.target

[Service]
Type=oneshot
RemainAfterExit=yes
WorkingDirectory=$APP_DIR
ExecStart=/usr/bin/docker compose up -d
ExecStop=/usr/bin/docker compose down

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable --now ghost-blog.service

docker compose pull
docker compose up -d
