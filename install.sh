#!/bin/bash

# Jellyfin + Nginx + Let's Encrypt (Certbot) installer
# Поддерживаемые ОС: Ubuntu 20.04/22.04/24.04, Debian 11/12
# Требуются права root (sudo)
# Один запуск — установка Jellyfin, Nginx, получение/обновление SSL через Let's Encrypt
# Пользователь вводит: домен, email для Let's Encrypt

set -e

# Цвета для вывода
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log() { echo -e "${GREEN}[INFO]${NC} $1"; }
warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
error() { echo -e "${RED}[ERROR]${NC} $1" >&2; }

# Проверка root
if [[ $EUID -ne 0 ]]; then
   error "Скрипт должен запускаться от root (или через sudo)"
   exit 1
fi

# Определение ОС
if [[ -f /etc/os-release ]]; then
    . /etc/os-release
    OS=$ID
    VER=$VERSION_ID
else
    error "Не поддерживаемая ОС"
    exit 1
fi

log "Обнаружена ОС: $OS $VER"

# Поддерживаемые дистрибутивы
case "$OS" in
    ubuntu|debian) ;;
    *) error "Поддерживаются только Ubuntu и Debian"; exit 1 ;;
esac

# === ВВОД ПОЛЬЗОВАТЕЛЯ ===
read -p "Введите доменное имя (например, jellyfin.example.com): " DOMAIN
if [[ -z "$DOMAIN" ]]; then
    error "Домен обязателен"
    exit 1
fi

read -p "Введите email для Let's Encrypt (уведомления об истечении): " EMAIL
if [[ -z "$EMAIL" ]]; then
    warn "Email не указан — будут отключены уведомления"
    EMAIL="none"
fi

read -p "Открыть порты 80/443 в ufw? (y/n, по умолчанию y): " OPEN_UFW
OPEN_UFW=${OPEN_UFW:-y}

# === УСТАНОВКА ЗАВИСИМОСТЕЙ ===
log "Обновление пакетов..."
apt update -y
apt upgrade -y

log "Установка базовых утилит..."
apt install -y curl gnupg software-properties-common ufw

# === УСТАНОВКА JELLYFIN ===
log "Добавление репозитория Jellyfin..."
curl -fsSL https://repo.jellyfin.org/ubuntu/jellyfin_team.gpg.key | gpg --dearmor -o /etc/apt/trusted.gpg.d/jellyfin.gpg
echo "deb [arch=$(dpkg --print-architecture)] https://repo.jellyfin.org/$OS $VERSION_CODENAME main" > /etc/apt/sources.list.d/jellyfin.list

apt update -y
log "Установка Jellyfin..."
apt install -y jellyfin

log "Запуск и автозапуск Jellyfin..."
systemctl enable --now jellyfin

# Проверка статуса
if systemctl is-active --quiet jellyfin; then
    log "Jellyfin запущен[](http://localhost:8096)"
else
    error "Jellyfin не запустился!"
    exit 1
fi

# === УСТАНОВКА NGINX ===
log "Установка Nginx..."
apt install -y nginx

# === НАСТРОЙКА UFW (если нужно) ===
if [[ "$OPEN_UFW" =~ ^[Yy]$ ]]; then
    log "Настройка firewall (ufw)..."
    ufw allow 'Nginx Full'
    ufw allow ssh  # на всякий случай
    ufw --force enable
fi

# === LET'S ENCRYPT (Certbot) ===
log "Установка Certbot..."
apt install -y certbot python3-certbot-nginx

log "Получение SSL-сертификата для $DOMAIN..."
if [[ "$EMAIL" == "none" ]]; then
    certbot --nginx -d "$DOMAIN" --non-interactive --agree-tos --redirect
else
    certbot --nginx -d "$DOMAIN" --non-interactive --agree-tos -m "$EMAIL" --redirect
fi

# Проверка сертификата
if [[ -f "/etc/letsencrypt/live/$DOMAIN/fullchain.pem" ]]; then
    log "SSL-сертификат успешно получен!"
else
    error "Не удалось получить сертификат. Проверьте DNS и доступность порта 80."
    exit 1
fi

# === НАСТРОЙКА NGINX ===
log "Создание конфигурации Nginx для Jellyfin..."

cat > /etc/nginx/sites-available/jellyfin <<EOF
server {
    listen 80;
    listen [::]:80;
    server_name $DOMAIN;

    # Перенаправление на HTTPS (Certbot уже добавил, но на всякий)
    return 301 https://\$server_name\$request_uri;
}

server {
    listen 443 ssl http2;
    listen [::]:443 ssl http2;
    server_name $DOMAIN;

    ssl_certificate /etc/letsencrypt/live/$DOMAIN/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/$DOMAIN/privkey.pem;
    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_ciphers ECDHE-RSA-AES256-GCM-SHA512:DHE-RSA-AES256-GCM-SHA512:ECDHE-RSA-AES256-GCM-SHA384:DHE-RSA-AES256-GCM-SHA384;
    ssl_prefer_server_ciphers off;

    # Улучшения безопасности
    add_header Strict-Transport-Security "max-age=63072000" always;
    add_header X-Content-Type-Options nosniff;
    add_header X-Frame-Options DENY;

    client_max_body_size 100M;

    location / {
        proxy_pass http://127.0.0.1:8096;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_set_header X-Forwarded-Host \$host;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";

        proxy_http_version 1.1;
        proxy_buffering off;
        proxy_cache off;
    }

    # WebSocket для Jellyfin
    location /socket {
        proxy_pass http://127.0.0.1:8096;
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header Host \$host;
    }
}
EOF

# Активация сайта
rm -f /etc/nginx/sites-enabled/default
ln -sf /etc/nginx/sites-available/jellyfin /etc/nginx/sites-enabled/

# Проверка конфигурации
nginx -t
if [[ $? -eq 0 ]]; then
    log "Перезапуск Nginx..."
    systemctl restart nginx
else
    error "Ошибка в конфигурации Nginx!"
    exit 1
fi

# === ОБНОВЛЕНИЕ СЕРТИФИКАТА (cron) ===
log "Настройка автообновления сертификата (ежедневно в 3:17)..."
CRON_LINE="17 3 * * * root certbot renew --quiet --post-hook 'systemctl reload nginx'"
(crontab -l 2>/dev/null | grep -v "certbot renew"; echo "$CRON_LINE") | crontab -

# === ГОТОВО ===
log "УСТАНОВКА ЗАВЕРШЕНА!"
echo
echo "   Jellyfin доступен по адресу: https://$DOMAIN"
echo "   Админ-панель: https://$DOMAIN (первый запуск — создание пользователя)"
echo
echo "   Сертификат будет обновляться автоматически (cron)."
echo "   Проверьте статус: systemctl status jellyfin nginx"
echo
warn "Убедитесь, что A-запись $DOMAIN указывает на этот сервер!"
