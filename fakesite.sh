#!/bin/bash

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

show_progress() {
    local current=$1 total=$2 status=$3
    local percent=$((current * 100 / total))
    local filled=$((percent / 2)) empty=$((50 - filled))
    printf "\r${CYAN}["
    printf "%${filled}s" | tr ' ' '='
    printf "%${empty}s" | tr ' ' ' '
    printf "] ${GREEN}%3d%%${NC} ${YELLOW}%s${NC}" "$percent" "$status"
}

show_complete() { echo -e "\n${GREEN}[OK]${NC} ${1}"; }
show_error()    { echo -e "\n${RED}[ERROR]${NC} ${1}"; }

execute_silent() {
    local log_file="/tmp/sni_setup_$(date +%s).log"
    eval "$1" >> "$log_file" 2>&1
    return $?
}

clear
echo -e "${CYAN}=====================================================${NC}"
echo -e "${CYAN}  Установка и настройка Self SNI Scripts by begugla  ${NC}"
echo -e "${CYAN}=====================================================${NC}"
echo ""

TOTAL_STEPS=13
CURRENT_STEP=0

# Шаг 1: Проверка ОС
CURRENT_STEP=$((CURRENT_STEP + 1))
show_progress $CURRENT_STEP $TOTAL_STEPS "Проверка операционной системы..."
sleep 0.3
if ! grep -E -q "^(ID=debian|ID=ubuntu)" /etc/os-release; then
    show_error "Система не поддерживается. Требуется Debian или Ubuntu."
    exit 1
fi
show_complete "Операционная система совместима"

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
        if [[ -z "$THEME" ]]; then
            THEME="Современная компания"
        fi
        ;;
    *) THEME="IT-компания и технологические решения" ;;
esac

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
show_complete "Внешний IP сервера: $external_ip"

# Шаг 6: DNS A-запись
CURRENT_STEP=$((CURRENT_STEP + 1))
show_progress $CURRENT_STEP $TOTAL_STEPS "Проверка A-записи домена..."
domain_ip=$(dig +short A "$DOMAIN" | head -n1)
if [[ -z "$domain_ip" ]]; then
    show_error "Не удалось получить A-запись для домена $DOMAIN"
    exit 1
fi
show_complete "A-запись домена: $domain_ip"

# Шаг 7: Сравнение IP
CURRENT_STEP=$((CURRENT_STEP + 1))
show_progress $CURRENT_STEP $TOTAL_STEPS "Проверка соответствия DNS записи..."
if [[ "$domain_ip" != "$external_ip" ]]; then
    show_error "A-запись домена не соответствует внешнему IP сервера"
    exit 1
fi
show_complete "DNS записи корректны"

# Шаг 8: Остановка nginx
CURRENT_STEP=$((CURRENT_STEP + 1))
show_progress $CURRENT_STEP $TOTAL_STEPS "Остановка nginx..."
systemctl stop nginx 2>/dev/null || true
show_complete "Nginx остановлен"

# Шаг 9: Проверка портов
CURRENT_STEP=$((CURRENT_STEP + 1))
show_progress $CURRENT_STEP $TOTAL_STEPS "Проверка портов 80 и 443..."
if ss -tuln | grep -q ":443 "; then
    show_error "Порт 443 занят"; exit 1
fi
if ss -tuln | grep -q ":80 "; then
    show_error "Порт 80 занят"; exit 1
fi
show_complete "Порты 80 и 443 свободны"

# Шаг 10: Генерация сайта через ИИ
CURRENT_STEP=$((CURRENT_STEP + 1))
show_progress $CURRENT_STEP $TOTAL_STEPS "Генерация сайта через ИИ (тема: $THEME)..."

AI_PROMPT="You are an expert front-end developer. Generate a complete, production-ready single-file website for the following theme: \\\"${THEME}\\\".

STRICT OUTPUT RULES — FOLLOW EXACTLY:
- Output ONLY the raw HTML document. Start with <!DOCTYPE html> on the very first character.
- Do NOT wrap in markdown fences (\`\`\`html or \`\`\`).
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

AI_REQUEST=$(jq -n \
    --arg prompt "$AI_PROMPT" \
    '{
        model: "openai-fast",
        messages: [{role: "user", content: $prompt}]
    }')

AI_RESPONSE=$(curl -s --max-time 120 \
    -H "accept: */*" \
    -H "authorization: Bearer pk_XDXnwCpYbihkQcEg" \
    -H "content-type: application/json" \
    -H "origin: https://pollinations.ai" \
    -H "referer: https://pollinations.ai/" \
    "https://gen.pollinations.ai/v1/chat/completions" \
    -d "$AI_REQUEST")

GENERATED_HTML=$(echo "$AI_RESPONSE" | jq -r '.choices[0].message.content // empty')

if [[ -z "$GENERATED_HTML" ]] || ! echo "$GENERATED_HTML" | grep -qi "<!DOCTYPE"; then
    show_error "ИИ не вернул корректный HTML, устанавливаем заглушку..."
    cat > /var/www/html/index.html <<FALLBACK
<!DOCTYPE html>
<html lang="ru">
<head><meta charset="UTF-8"><title>${DOMAIN}</title>
<style>body{background:#0b1020;color:#e8e8f0;font-family:sans-serif;display:flex;align-items:center;justify-content:center;height:100vh;margin:0;}h1{font-size:2rem;}</style>
</head>
<body><h1>${DOMAIN}</h1></body>
</html>
FALLBACK
else
    echo "$GENERATED_HTML" > /var/www/html/index.html
    show_complete "Сайт сгенерирован ИИ и сохранён"
fi

# Шаг 11: SSL сертификат
CURRENT_STEP=$((CURRENT_STEP + 1))
show_progress $CURRENT_STEP $TOTAL_STEPS "Получение SSL сертификата (может занять время)..."
if execute_silent "certbot certonly --standalone -d $DOMAIN --agree-tos -m admin@$DOMAIN --non-interactive"; then
    show_complete "SSL сертификат успешно получен"
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
    show_complete "Автопродление настроено (systemd timer + Persistent)"
elif [ -f /etc/cron.d/certbot ]; then
    show_complete "Автопродление настроено (cron)"
else
    cat > /etc/cron.d/certbot <<'CRONEOF'
SHELL=/bin/sh
PATH=/usr/local/sbin:/usr/local/bin:/sbin:/bin:/usr/sbin:/usr/bin
0 */12 * * * root certbot -q renew --nginx
CRONEOF
    show_complete "Автопродление настроено (новый cron)"
fi
execute_silent "certbot renew --dry-run" || true

# Шаг 12: Конфигурация Nginx
CURRENT_STEP=$((CURRENT_STEP + 1))
show_progress $CURRENT_STEP $TOTAL_STEPS "Создание конфигурации Nginx..."

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

    ssl_stapling on;
    ssl_stapling_verify on;

    resolver 8.8.8.8 8.8.4.4 valid=300s;
    resolver_timeout 5s;

    real_ip_header proxy_protocol;
    set_real_ip_from 127.0.0.1;

    location / {
        root /var/www/html;
        index index.html;
    }
}
EOF

rm -f /etc/nginx/sites-enabled/default
show_complete "Конфигурация Nginx создана"

# Шаг 13: Запуск Nginx
CURRENT_STEP=$((CURRENT_STEP + 1))
show_progress $CURRENT_STEP $TOTAL_STEPS "Запуск Nginx..."
if nginx -t > /dev/null 2>&1 && systemctl start nginx > /dev/null 2>&1; then
    show_complete "Nginx успешно запущен"
else
    show_error "Ошибка при запуске Nginx"
    exit 1
fi

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
echo ""
echo -e "${GREEN}Скрипт завершен!${NC}"
