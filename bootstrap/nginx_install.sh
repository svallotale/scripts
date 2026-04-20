#!/bin/bash

DOMAIN="$1"
PROXY_PORT="$2"
EMAIL="$3"

if [ -z "$DOMAIN" ] || [ -z "$PROXY_PORT" ] || [ -z "$EMAIL" ]; then
  echo "Usage: $0 domain proxy_port email"
  exit 1
fi

# Установка nginx и certbot
sudo apt update
sudo apt install -y nginx certbot python3-certbot-nginx

# Создание nginx-конфигурации для домена (HTTP для ACME-challenge)
NGINX_CONF="/etc/nginx/sites-available/$DOMAIN"
sudo tee $NGINX_CONF > /dev/null <<EOF
server {
  listen 80;
  server_name $DOMAIN;
  location / {
    proxy_pass http://localhost:$PROXY_PORT;
    proxy_http_version 1.1;
    proxy_set_header Upgrade \$http_upgrade;
    proxy_set_header Connection 'upgrade';
    proxy_set_header Host \$host;
    proxy_cache_bypass \$http_upgrade;
  }
}
EOF

# Активация сайта
sudo ln -s $NGINX_CONF /etc/nginx/sites-enabled/
sudo nginx -t || exit 2
sudo systemctl reload nginx

# Запуск certbot (без интерактива)
sudo certbot --nginx -n --agree-tos --redirect --email "$EMAIL" -d "$DOMAIN"

# Перезапуск Nginx после установки сертификата
sudo systemctl reload nginx

echo "Done. $DOMAIN проксирует на порт $PROXY_PORT через nginx с SSL Let’s Encrypt."
