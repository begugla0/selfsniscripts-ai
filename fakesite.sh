#!/bin/bash

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

LOG_FILE="/var/log/sni_setup_$(date +%Y%m%d_%H%M%S).log"

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" >> "$LOG_FILE"
}

show_progress() {
    local current=$1 total=$2 status=$3
    local percent=$((current * 100 / total))
    local filled=$((percent / 2)) empty=$((50 - filled))
    printf "\r${CYAN}["
    printf "%${filled}s" | tr ' ' '='
    printf "%${empty}s" | tr ' ' ' '
    printf "] ${GREEN}%3d%%${NC} ${YELLOW}%s${NC}" "$percent" "$status"
}

show_complete() {
    echo -e "\n${GREEN}[OK]${NC} ${1}"
    log "[OK] $1"
}

show_error() {
    echo -e "\n${RED}[ERROR]${NC} ${1}"
    log "[ERROR] $1"
    echo -e "${YELLOW}Лог: $LOG_FILE${NC}"
}

show_warn() {
    echo -e "\n${YELLOW}[WARN]${NC} ${1}"
    log "[WARN] $1"
}

execute_silent() {
    local cmd=$1
    log "CMD: $cmd"
    eval "$cmd" >> "$LOG_FILE" 2>&1
    local exit_code=$?
    log "EXIT: $exit_code"
    return $exit_code
}

clear
echo -e "${CYAN}=====================================================${NC}"
echo -e "${CYAN}  Установка и настройка Self SNI Scripts by begugla  ${NC}"
echo -e "${CYAN}=====================================================${NC}"
echo -e " ${BLUE}Лог установки:${NC} $LOG_FILE"
echo ""
log "=== Начало установки ==="
log "Версия скрипта: 3.1.0"

TOTAL_STEPS=13
CURRENT_STEP=0

# Шаг 1: Проверка ОС
CURRENT_STEP=$((CURRENT_STEP + 1))
show_progress $CURRENT_STEP $TOTAL_STEPS "Проверка операционной системы..."
sleep 0.3
log "Проверка /etc/os-release"
OS_INFO=$(grep -E "^(ID|VERSION_ID|PRETTY_NAME)=" /etc/os-release | tr '\n' ' ')
log "ОС: $OS_INFO"
if ! grep -E -q "^(ID=debian|ID=ubuntu)" /etc/os-release; then
    show_error "Система не поддерживается. Требуется Debian или Ubuntu."
    exit 1
fi
OS_NAME=$(grep PRETTY_NAME /etc/os-release | cut -d'"' -f2)
show_complete "ОС совместима: $OS_NAME"

# Шаг 2: Запрос параметров
CURRENT_STEP=$((CURRENT_STEP + 1))
show_progress $CURRENT_STEP $TOTAL_STEPS "Ожидание ввода данных..."
echo ""
read -p "Введите доменное имя: " DOMAIN
if [[ -z "$DOMAIN" ]]; then
    show_error "Доменное имя не может быть пустым"
    exit 1
fi
read -p "Введите внутренний SNI Self порт (Enter для 9000): " SPORT
SPORT=${SPORT:-9000}

echo ""
echo -e "${CYAN}Доступные тематики сайта:${NC}"
echo -e "  ${YELLOW}1${NC}) IT / Технологии"
echo -e "  ${YELLOW}2${NC}) Медицина / Здоровье"
echo -e "  ${YELLOW}3${NC}) Финансы / Инвестиции"
echo -e "  ${YELLOW}4${NC}) Образование / Курсы"
echo -e "  ${YELLOW}5${NC}) Строительство / Недвижимость"
echo -e "  ${YELLOW}6${NC}) Ресторан / Еда"
echo -e "  ${YELLOW}7${NC}) Своя тема (ввод вручную)"
read -p "Выберите тематику [1-7]: " THEME_CHOICE

case "$THEME_CHOICE" in
    1) THEME="IT-компания и технологические решения" ;;
    2) THEME="Медицинский центр и здоровье" ;;
    3) THEME="Финансовые услуги и инвестиции" ;;
    4) THEME="Образовательная платформа и онлайн-курсы" ;;
    5) THEME="Строительная компания и недвижимость" ;;
    6) THEME="Ресторан и доставка еды" ;;
    7)
        read -p "Введите свою тему на русском: " THEME
        [[ -z "$THEME" ]] && THEME="Современная компания"
        ;;
    *) THEME="IT-компания и технологические решения" ;;
esac

log "Домен: $DOMAIN | Порт: $SPORT | Тема: $THEME"
show_complete "Параметры получены (тема: $THEME)"

# Шаг 3: Обновление пакетов
CURRENT_STEP=$((CURRENT_STEP + 1))
show_progress $CURRENT_STEP $TOTAL_STEPS "Обновление списка пакетов..."
if execute_silent "apt update"; then
    show_complete "Список пакетов обновлен"
else
    show_error "Не удалось обновить список пакетов"
    exit 1
fi

# Шаг 4: Установка зависимостей
CURRENT_STEP=$((CURRENT_STEP + 1))
show_progress $CURRENT_STEP $TOTAL_STEPS "Установка компонентов (nginx, certbot, git, jq)..."
if execute_silent "DEBIAN_FRONTEND=noninteractive apt install -y nginx certbot python3-certbot-nginx git curl dnsutils jq"; then
    show_complete "Компоненты успешно установлены"
else
    show_error "Не удалось установить необходимые компоненты"
    exit 1
fi

# Шаг 5: Внешний IP
CURRENT_STEP=$((CURRENT_STEP + 1))
show_progress $CURRENT_STEP $TOTAL_STEPS "Определение внешнего IP сервера..."
external_ip=$(curl -s --max-time 5 https://api.ipify.org)
if [[ -z "$external_ip" ]]; then
    show_error "Не удалось определить внешний IP сервера"
    exit 1
fi
log "Внешний IP: $external_ip"
show_complete "Внешний IP сервера: $external_ip"

# Шаг 6: DNS A-запись
CURRENT_STEP=$((CURRENT_STEP + 1))
show_progress $CURRENT_STEP $TOTAL_STEPS "Проверка A-записи домена..."
domain_ip=$(dig +short A "$DOMAIN" | head -n1)
if [[ -z "$domain_ip" ]]; then
    show_error "Не удалось получить A-запись для домена $DOMAIN"
    exit 1
fi
log "A-запись $DOMAIN -> $domain_ip"
show_complete "A-запись домена: $domain_ip"

# Шаг 7: Сравнение IP
CURRENT_STEP=$((CURRENT_STEP + 1))
show_progress $CURRENT_STEP $TOTAL_STEPS "Проверка соответствия DNS записи..."
if [[ "$domain_ip" != "$external_ip" ]]; then
    show_error "A-запись ($domain_ip) не соответствует IP сервера ($external_ip)"
    exit 1
fi
show_complete "DNS записи корректны"

# Шаг 8: Остановка nginx
CURRENT_STEP=$((CURRENT_STEP + 1))
show_progress $CURRENT_STEP $TOTAL_STEPS "Остановка nginx..."
systemctl stop nginx 2>/dev/null || true
log "nginx остановлен"
show_complete "Nginx остановлен"

# Шаг 9: Проверка портов
CURRENT_STEP=$((CURRENT_STEP + 1))
show_progress $CURRENT_STEP $TOTAL_STEPS "Проверка портов 80 и 443..."
log "Занятые порты: $(ss -tuln | grep -E ':80 |:443 ' || echo 'нет')"
if ss -tuln | grep -q ":443 "; then
    show_error "Порт 443 занят. $(ss -tuln | grep ':443 ')"
    exit 1
fi
if ss -tuln | grep -q ":80 "; then
    show_error "Порт 80 занят. $(ss -tuln | grep ':80 ')"
    exit 1
fi
show_complete "Порты 80 и 443 свободны"

# Шаг 10: Генерация сайта через ИИ
CURRENT_STEP=$((CURRENT_STEP + 1))
show_progress $CURRENT_STEP $TOTAL_STEPS "Генерация сайта через ИИ (тема: $THEME)..."
log "Отправка запроса к Pollinations AI..."

AI_PROMPT="You are an expert front-end developer. Generate a complete, production-ready single-file website for the following theme: \\\"${THEME}\\\".

STRICT OUTPUT RULES — FOLLOW EXACTLY:
- Output ONLY the raw HTML document. Start with <!DOCTYPE html> on the very first character.
- Do NOT wrap in markdown fences.
- Do NOT add any explanation, commentary, preamble, or text outside the HTML.
- Do NOT include HTML comments (<!-- ... -->).

DESIGN REQUIREMENTS:
- Single .html file: all CSS in <style>, all JS in <script> — no external CDN links.
- Dark, modern aesthetic with a hero section, navigation, features/services section, and footer.
- Rich CSS animations: fade-in on load, parallax-like hero, card hover lift + glow, animated gradient background or floating particles via canvas/CSS.
- Smooth scroll, intersection observer reveal animations on scroll.
- Fully responsive (mobile-first). Hamburger menu on mobile.
- Believable content: realistic company name, tagline, 3-6 service cards with icons (inline SVG), testimonials or stats block.
- CTA button with ripple animation on click.
- Color palette based on theme, glassmorphism cards.
- Language: Russian."

AI_REQUEST=$(jq -n --arg prompt "$AI_PROMPT" \
    '{model: "openai-fast", messages: [{role: "user", content: $prompt}]}')

log "Запрос к API сформирован, ожидание ответа (timeout 120s)..."

AI_RESPONSE=$(curl -s --max-time 120 \
    -H "accept: */*" \
    -H "authorization: Bearer pk_XDXnwCpYbihkQcEg" \
    -H "content-type: application/json" \
    -H "origin: https://pollinations.ai" \
    -H "referer: https://pollinations.ai/" \
    "https://gen.pollinations.ai/v1/chat/completions" \
    -d "$AI_REQUEST")

AI_EXIT=$?
log "curl exit code: $AI_EXIT"
log "Размер ответа: ${#AI_RESPONSE} байт"

if [[ $AI_EXIT -ne 0 ]]; then
    show_warn "curl вернул ошибку (код $AI_EXIT), используем fallback"
    log "Ответ API: $AI_RESPONSE"
fi

GENERATED_HTML=$(echo "$AI_RESPONSE" | jq -r '.choices[0].message.content // empty' 2>/dev/null)

log "Размер HTML: ${#GENERATED_HTML} символов"

if [[ -z "$GENERATED_HTML" ]] || ! echo "$GENERATED_HTML" | grep -qi "<!DOCTYPE"; then
    show_warn "ИИ не вернул корректный HTML, используем fallback страницу"
    log "Fallback причина: пустой ответ или нет DOCTYPE"
    log "Raw response: ${AI_RESPONSE:0:500}"
    cat > /var/www/html/index.html <<FALLBACK
<!DOCTYPE html>
<html lang="ru">
<head><meta charset="UTF-8"><title>${DOMAIN}</title>
<style>
  body{background:#0b1020;color:#e8e8f0;font-family:sans-serif;
       display:flex;align-items:center;justify-content:center;
       height:100vh;margin:0;flex-direction:column;gap:12px;}
  h1{font-size:2rem;margin:0;}
  p{color:#a6a6b7;}
</style>
</head>
<body><h1>${DOMAIN}</h1><p>Сайт временно недоступен</p></body>
</html>
FALLBACK
    show_warn "Установлена fallback страница"
else
    echo "$GENERATED_HTML" > /var/www/html/index.html
    log "HTML записан в /var/www/html/index.html (${#GENERATED_HTML} символов)"
    show_complete "Сайт сгенерирован ИИ и сохранён (${#GENERATED_HTML} символов)"
fi

# Шаг 11: SSL сертификат
CURRENT_STEP=$((CURRENT_STEP + 1))
show_progress $CURRENT_STEP $TOTAL_STEPS "Получение SSL сертификата (может занять время)..."
log "Запуск certbot для $DOMAIN"
if execute_silent "certbot certonly --standalone -d $DOMAIN --agree-tos -m admin@$DOMAIN --non-interactive"; then
    CERT_EXPIRY=$(openssl x509 -enddate -noout -in /etc/letsencrypt/live/$DOMAIN/fullchain.pem 2>/dev/null | cut -d= -f2)
    log "Сертификат получен, истекает: $CERT_EXPIRY"
    show_complete "SSL сертификат получен (действует до: $CERT_EXPIRY)"
else
    show_error "Не удалось получить SSL сертификат"
    exit 1
fi

# Автопродление
if systemctl list-timers 2>/dev/null | grep -q certbot.timer; then
    systemctl enable certbot.timer 2>/dev/null || true
    systemctl start certbot.timer 2>/dev/null || true
    if ! systemctl cat certbot.timer 2>/dev/null | grep -q "Persistent=true"; then
        mkdir -p /etc/systemd/system/certbot.timer.d/
        printf '[Timer]\nPersistent=true\n' > /etc/systemd/system/certbot.timer.d/override.conf
        systemctl daemon-reload
        systemctl restart certbot.timer
    fi
    log "Автопродление: systemd timer"
    show_complete "Автопродление настроено (systemd timer + Persistent)"
elif [ -f /etc/cron.d/certbot ]; then
    log "Автопродление: cron уже есть"
    show_complete "Автопродление настроено (cron)"
else
    cat > /etc/cron.d/certbot <<'CRONEOF'
SHELL=/bin/sh
PATH=/usr/local/sbin:/usr/local/bin:/sbin:/bin:/usr/sbin:/usr/bin
0 */12 * * * root certbot -q renew --nginx
CRONEOF
    log "Автопродление: создан cron"
    show_complete "Автопродление настроено (новый cron)"
fi
execute_silent "certbot renew --dry-run" || true

# Шаг 12: Конфигурация Nginx (с фиксами)
CURRENT_STEP=$((CURRENT_STEP + 1))
show_progress $CURRENT_STEP $TOTAL_STEPS "Создание конфигурации Nginx..."
log "Создание /etc/nginx/sites-enabled/sni.conf"

# Фикс: server_names_hash_bucket_size
if ! grep -q "server_names_hash_bucket_size" /etc/nginx/nginx.conf; then
    sed -i '/http {/a\\tserver_names_hash_bucket_size 128;' /etc/nginx/nginx.conf
    log "Добавлен server_names_hash_bucket_size 128"
else
    sed -i 's/.*server_names_hash_bucket_size.*/\tserver_names_hash_bucket_size 128;/' /etc/nginx/nginx.conf
    log "Обновлен server_names_hash_bucket_size 128"
fi

# Фикс: удаляем все старые конфиги кроме sni.conf
for f in /etc/nginx/sites-enabled/*; do
    [[ "$(basename $f)" != "sni.conf" ]] && { rm -f "$f"; log "Удален конфиг: $f"; }
done

cat > /etc/nginx/sites-enabled/sni.conf <<EOF
server {
    listen 80;
    server_name $DOMAIN;
    if (\$host = $DOMAIN) {
        return 301 https://\$host\$request_uri;
    }
    return 404;
}

server {
    listen 127.0.0.1:$SPORT ssl http2;
    server_name $DOMAIN;

    ssl_certificate /etc/letsencrypt/live/$DOMAIN/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/$DOMAIN/privkey.pem;

    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_prefer_server_ciphers on;
    ssl_ciphers "ECDHE-ECDSA-AES256-GCM-SHA384:ECDHE-RSA-AES256-GCM-SHA384";

    real_ip_header proxy_protocol;
    set_real_ip_from 127.0.0.1;

    location / {
        root /var/www/html;
        index index.html;
    }
}
EOF

log "nginx.conf проверка:"
nginx -t >> "$LOG_FILE" 2>&1
NGINX_TEST=$?
log "nginx -t exit code: $NGINX_TEST"

if [[ $NGINX_TEST -ne 0 ]]; then
    show_error "Ошибка в конфигурации Nginx (см. лог: $LOG_FILE)"
    nginx -t
    exit 1
fi
show_complete "Конфигурация Nginx создана и проверена"

# Шаг 13: Запуск Nginx
CURRENT_STEP=$((CURRENT_STEP + 1))
show_progress $CURRENT_STEP $TOTAL_STEPS "Запуск Nginx..."
if systemctl start nginx; then
    NGINX_STATUS=$(systemctl is-active nginx)
    log "nginx статус: $NGINX_STATUS"
    show_complete "Nginx запущен (статус: $NGINX_STATUS)"
else
    show_error "Ошибка при запуске Nginx"
    log "journalctl nginx:"
    journalctl -u nginx --no-pager -n 30 >> "$LOG_FILE" 2>&1
    echo -e "${YELLOW}Подробности в логе: $LOG_FILE${NC}"
    exit 1
fi

log "=== Установка завершена успешно ==="

echo ""
echo -e "${CYAN}=====================================================${NC}"
echo -e "${CYAN}          Установка завершена успешно!              ${NC}"
echo -e "${CYAN}=====================================================${NC}"
echo ""
echo -e "${GREEN}Параметры для подключения:${NC}"
echo -e "${BLUE}-----------------------------------------------------${NC}"
echo -e " ${YELLOW}Сертификат:${NC} /etc/letsencrypt/live/$DOMAIN/fullchain.pem"
echo -e " ${YELLOW}Ключ:${NC}        /etc/letsencrypt/live/$DOMAIN/privkey.pem"
echo -e " ${YELLOW}Dest:${NC}        127.0.0.1:$SPORT"
echo -e " ${YELLOW}SNI:${NC}         $DOMAIN"
echo -e " ${YELLOW}Тема сайта:${NC}  $THEME"
echo -e "${BLUE}-----------------------------------------------------${NC}"
echo -e " ${CYAN}Лог установки:${NC} $LOG_FILE"
echo ""
echo -e "${GREEN}Скрипт завершен!${NC}"
