#!/bin/bash
set -euo pipefail

# ─── Цвета ────────────────────────────────────────────────────────────────────
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
MAGENTA='\033[0;35m'
NC='\033[0m'

# ─── Константы ────────────────────────────────────────────────────────────────
SCRIPT_VERSION="2.1.0"
SCRIPT_NAME="Self SNI Scripts"
GITHUB_URL="https://github.com/begugla0/selfsniscripts"
LOG_FILE="/var/log/sni_setup_$(date +%Y%m%d_%H%M%S).log"
NGINX_CONF_DIR="/etc/nginx/sites-enabled"
WEBROOT="/var/www/html"
AI_API_URL="https://text.pollinations.ai/openai"
AI_MODEL="openai-fast"

TOTAL_STEPS=14
CURRENT_STEP=0

# ─── Утилиты ──────────────────────────────────────────────────────────────────

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" >> "$LOG_FILE"; }

show_progress() {
    local current=$1 total=$2 status=$3
    local percent=$((current * 100 / total))
    local filled=$((percent / 2))
    local empty=$((50 - filled))
    printf "\r${CYAN}[%s%s]${NC} ${GREEN}%3d%%${NC} ${YELLOW}%s${NC}" \
        "$(printf '%*s' "$filled" '' | tr ' ' '=')" \
        "$(printf '%*s' "$empty" '')" \
        "$percent" "$status"
}

step() {
    CURRENT_STEP=$((CURRENT_STEP + 1))
    show_progress "$CURRENT_STEP" "$TOTAL_STEPS" "$1"
    log "STEP $CURRENT_STEP/$TOTAL_STEPS: $1"
}

ok()   { echo -e "\n${GREEN}[OK]${NC} $1";    log "OK: $1"; }
warn() { echo -e "\n${YELLOW}[WARN]${NC} $1"; log "WARN: $1"; }
die()  {
    echo -e "\n${RED}[ERROR]${NC} $1"
    log "ERROR: $1"
    [[ -n "${2:-}" ]] && echo -e "${YELLOW}Подробнее: $2${NC}"
    echo -e "${YELLOW}Лог: $LOG_FILE${NC}"
    exit 1
}

run() { log "RUN: $*"; eval "$*" >> "$LOG_FILE" 2>&1; }

require_root() {
    [[ "$EUID" -eq 0 ]] || die "Скрипт должен быть запущен от root (sudo)"
}

wait_apt_lock() {
    local i=0
    while fuser /var/lib/dpkg/lock-frontend /var/cache/apt/archives/lock > /dev/null 2>&1; do
        (( i++ > 60 )) && die "APT заблокирован другим процессом."
        printf "\r${YELLOW}Ожидание APT lock... %ds${NC}" "$i"
        sleep 1
    done
}

detect_os() {
    [[ -f /etc/os-release ]] || die "Не найден /etc/os-release"
    # shellcheck disable=SC1091
    source /etc/os-release
    OS_ID="${ID:-unknown}"
    OS_VERSION="${VERSION_ID:-unknown}"
    OS_LIKE="${ID_LIKE:-}"
    case "$OS_ID" in
        ubuntu|debian) ;;
        *)
            if [[ "$OS_LIKE" =~ (ubuntu|debian) ]]; then
                warn "Производная система ($OS_ID). Продолжаем как Debian-совместимую."
            else
                die "ОС '$OS_ID' не поддерживается. Требуется Debian/Ubuntu."
            fi
            ;;
    esac
    ok "ОС: $OS_ID $OS_VERSION"
}

validate_domain() {
    echo "$1" | grep -qE '^([a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?\.)+[a-zA-Z]{2,}$' \
        || die "Некорректный формат домена: $1"
}

validate_port() {
    local port="$1"
    # Пустая строка — уже заменена дефолтом до вызова, но на всякий случай
    if [[ -z "$port" ]]; then
        die "Порт не может быть пустым"
    fi
    if ! [[ "$port" =~ ^[0-9]+$ ]]; then
        die "Порт должен быть числом: $port"
    fi
    if ! (( port >= 1 && port <= 65535 )); then
        die "Некорректный порт: $port (допустимо 1–65535)"
    fi
    if (( port < 1024 )); then
        warn "Порт $port < 1024 — привилегированный."
    fi
}


get_external_ip() {
    local ip=""
    for url in \
        "https://api.ipify.org" \
        "https://ifconfig.me" \
        "https://icanhazip.com" \
        "https://checkip.amazonaws.com"
    do
        ip=$(curl -s --max-time 5 "$url" 2>/dev/null | tr -d '[:space:]')
        [[ "$ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] && { echo "$ip"; return 0; }
    done
    return 1
}

check_port_free() {
    ss -tuln 2>/dev/null | grep -q ":${1} \|:${1}$" \
        && die "Порт $1 занят. Освободите его перед установкой." "$GITHUB_URL"
}

# ─── AI: промт ────────────────────────────────────────────────────────────────

build_ai_prompt() {
    local theme="$1"
    cat <<EOF
You are an expert front-end developer. Generate a complete, production-ready single-file website for the following theme: "${theme}".

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
- Language: Russian.
EOF
}

# ─── AI: запрос и парсинг ────────────────────────────────────────────────────

generate_ai_site() {
    local theme="$1"
    local output_file="$2"

    local prompt
    prompt=$(build_ai_prompt "$theme")

    local payload
    payload=$(python3 -c "
import json, sys
prompt = sys.stdin.read()
payload = {
    'model': '${AI_MODEL}',
    'messages': [{'role': 'user', 'content': prompt}]
}
print(json.dumps(payload))
" <<< "$prompt")

    log "AI запрос отправлен (тема: $theme)"

    local response
    response=$(curl -s --max-time 600 \
        -X POST "$AI_API_URL" \
        -H "content-type: application/json" \
        -d "$payload") || return 1

    log "AI ответ получён (длина: ${#response})"

    local html
    html=$(python3 -c "
import json, sys, re

raw = sys.stdin.read()
try:
    data = json.loads(raw)
    content = data['choices'][0]['message']['content']
except Exception as e:
    print('__PARSE_ERROR__: ' + str(e), file=sys.stderr)
    sys.exit(1)

content = re.sub(r'^\s*\`\`\`(?:html)?\s*', '', content, flags=re.IGNORECASE)
content = re.sub(r'\s*\`\`\`\s*$', '', content)
content = content.strip()

if not content.lower().startswith('<!doctype') and '<html' not in content.lower():
    print('__NOT_HTML__', file=sys.stderr)
    sys.exit(1)

print(content)
" <<< "$response") || return 1

    echo "$html" > "$output_file"
    return 0
}

# ─── AI: спиннер с анимацией ─────────────────────────────────────────────────

spinner() {
    local pid=$1
    local start_time elapsed minutes seconds

    local -a phases=(
        "0:1:🧠  Анализирую тематику сайта..."
        "1:2:💭  Придумываю структуру и разделы..."
        "2:3:🎨  Выбираю цветовую палитру и стиль..."
        "3:4:✍️   Пишу HTML-разметку..."
        "4:5:🎭  Добавляю CSS-анимации..."
        "5:6:⚙️   Пишу JavaScript..."
        "6:7:🖼️   Рисую SVG-иконки и иллюстрации..."
        "7:8:📱  Делаю адаптивную вёрстку..."
        "8:9:✨  Полирую визуальные эффекты..."
        "9:600:🔍  Финальная проверка и оформление..."
    )

    local frames='⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏'
    local frame_i=0
    local phase_label=""

    start_time=$(date +%s)

    # Резервируем 2 строки
    printf "\n\n"

    while kill -0 "$pid" 2>/dev/null; do
        elapsed=$(( $(date +%s) - start_time ))
        minutes=$(( elapsed / 60 ))
        seconds=$(( elapsed % 60 ))

        # Текущая фаза
        for phase in "${phases[@]}"; do
            local p_start p_end p_label
            p_start="${phase%%:*}"
            p_end="${phase#*:}"; p_end="${p_end%%:*}"
            p_label="${phase##*:}"
            if (( minutes >= p_start && minutes < p_end )); then
                phase_label="$p_label"
                break
            fi
        done

        # Прогресс-бар (600 сек = 100%)
        local max_sec=600
        local pct=$(( elapsed * 100 / max_sec ))
        (( pct > 99 )) && pct=99
        local filled=$(( pct * 30 / 100 ))
        local empty=$(( 30 - filled ))

        local bar_str=""
        local i
        for (( i=0; i<filled; i++ )); do bar_str+="█"; done
        for (( i=0; i<empty;  i++ )); do bar_str+="░"; done

        # Мигающая точка
        local dot
        (( (frame_i / 5) % 2 == 0 )) \
            && dot="${MAGENTA}●${NC}" \
            || dot="${BLUE}○${NC}"

        # Время и ETA
        local time_str eta_str
        printf -v time_str "%02d:%02d" "$minutes" "$seconds"
        if (( elapsed > 5 && elapsed < max_sec )); then
            local remaining=$(( max_sec - elapsed ))
            printf -v eta_str "ещё ~%02d:%02d" "$(( remaining/60 ))" "$(( remaining%60 ))"
        elif (( elapsed >= max_sec )); then
            eta_str="почти готово..."
        else
            eta_str="оцениваю время..."
        fi

        # Рендер: поднимаемся на 2 строки и перерисовываем
        printf "\033[2A"
        printf "\r  %b %s  ${CYAN}%s${NC}%60s\n" \
            "$dot" \
            "${frames:$((frame_i % ${#frames})):1}" \
            "$phase_label" ""
        printf "\r  ${CYAN}[${GREEN}%s${YELLOW}%s${CYAN}]${NC}  ${YELLOW}%s${NC}  ${BLUE}%s${NC}%30s\n" \
            "$bar_str" \
            "" \
            "$time_str" \
            "$eta_str" ""

        frame_i=$(( frame_i + 1 ))
        sleep 0.1
    done

    # Очищаем строки спиннера
    printf "\033[2A"
    printf "\r%80s\n\r%80s\n" "" ""
    printf "\033[2A"
}

# ─── Certbot автопродление ────────────────────────────────────────────────────

setup_certbot_renewal() {
    if systemctl list-timers 2>/dev/null | grep -q "certbot.timer"; then
        systemctl enable --now certbot.timer 2>/dev/null || true
        if ! systemctl cat certbot.timer 2>/dev/null | grep -q "Persistent=true"; then
            mkdir -p /etc/systemd/system/certbot.timer.d/
            cat > /etc/systemd/system/certbot.timer.d/override.conf <<'EOF'
[Timer]
Persistent=true
EOF
            systemctl daemon-reload
            systemctl restart certbot.timer 2>/dev/null || true
        fi
        ok "Автопродление: systemd timer (Persistent=true)"
    elif [[ -f /etc/cron.d/certbot ]]; then
        ok "Автопродление: cron (уже настроен)"
    else
        cat > /etc/cron.d/certbot <<'EOF'
SHELL=/bin/sh
PATH=/usr/local/sbin:/usr/local/bin:/sbin:/bin:/usr/sbin:/usr/bin
0 */12 * * * root certbot -q renew --nginx
EOF
        ok "Автопродление: cron (создан)"
    fi
    run "certbot renew --dry-run" || warn "dry-run завершился с ошибкой (некритично)"
}

# ─── Nginx конфиг ─────────────────────────────────────────────────────────────

write_nginx_config() {
    local domain=$1 sport=$2 conf_path=$3
    cat > "$conf_path" <<EOF
# Сгенерировано $SCRIPT_NAME v$SCRIPT_VERSION — $(date)
server {
    listen 80;
    server_name $domain;

    location /.well-known/acme-challenge/ {
        root $WEBROOT;
    }

    location / {
        return 301 https://\$host\$request_uri;
    }
}

server {
    listen 127.0.0.1:${sport} ssl;
    http2 on;

    server_name $domain;

    ssl_certificate         /etc/letsencrypt/live/$domain/fullchain.pem;
    ssl_certificate_key     /etc/letsencrypt/live/$domain/privkey.pem;
    ssl_trusted_certificate /etc/letsencrypt/live/$domain/chain.pem;

    ssl_protocols           TLSv1.2 TLSv1.3;
    ssl_prefer_server_ciphers on;
    ssl_ciphers             ECDHE-ECDSA-AES256-GCM-SHA384:ECDHE-RSA-AES256-GCM-SHA384:ECDHE-ECDSA-CHACHA20-POLY1305:ECDHE-RSA-CHACHA20-POLY1305;
    ssl_session_cache       shared:SSL:10m;
    ssl_session_timeout     1d;
    ssl_session_tickets     off;

    ssl_stapling            on;
    ssl_stapling_verify     on;
    resolver                1.1.1.1 8.8.8.8 valid=300s;
    resolver_timeout        5s;

    add_header Strict-Transport-Security "max-age=63072000; includeSubDomains; preload" always;
    add_header X-Frame-Options DENY always;
    add_header X-Content-Type-Options nosniff always;

    real_ip_header          proxy_protocol;
    set_real_ip_from        127.0.0.1;

    location / {
        root  $WEBROOT;
        index index.html index.htm;
        try_files \$uri \$uri/ =404;
    }
}
EOF
}

# ═══════════════════════════════════════════════════════════════════════════════
#  ТОЧКА ВХОДА
# ═══════════════════════════════════════════════════════════════════════════════

mkdir -p "$(dirname "$LOG_FILE")"
touch "$LOG_FILE"
log "=== $SCRIPT_NAME v$SCRIPT_VERSION started ==="

clear
echo -e "${CYAN}╔═════════════════════════════════════════════════════╗${NC}"
echo -e "${CYAN}║   $SCRIPT_NAME v$SCRIPT_VERSION by begugla          ║${NC}"
echo -e "${CYAN}╚═════════════════════════════════════════════════════╝${NC}"
echo ""

# ── 0. Root ──────────────────────────────────────────────────────────────────
require_root

# ── 1. Проверка ОС ───────────────────────────────────────────────────────────
step "Проверка операционной системы..."
detect_os

# ── 2. Ввод параметров ───────────────────────────────────────────────────────
step "Ожидание ввода данных..."
echo ""

read -rp "  Введите доменное имя:                           " DOMAIN
[[ -z "$DOMAIN" ]] && die "Доменное имя не может быть пустым"
validate_domain "$DOMAIN"

read -rp "  Email для Let's Encrypt (Enter = admin@$DOMAIN): " LE_EMAIL
LE_EMAIL="${LE_EMAIL:-admin@$DOMAIN}"

read -rp "  Внутренний SNI порт        (Enter = 9000):       " SPORT
SPORT="${SPORT:-9000}"
validate_port "$SPORT"

echo ""
echo -e "  ${CYAN}Тематика определяет что AI сгенерирует для сайта.${NC}"
echo -e "  ${YELLOW}Примеры:${NC} ремонт квартир, юридические услуги, кофейня,"
echo -e "           IT-компания, фитнес-клуб, медицинская клиника"
echo ""
read -rp "  Тематика сайта             (Enter = IT-компания): " SITE_THEME
SITE_THEME="${SITE_THEME:-IT-компания}"

ok "Параметры: домен=$DOMAIN  порт=$SPORT  тема=\"$SITE_THEME\""

# ── 3. Обновление пакетов ────────────────────────────────────────────────────
step "Обновление списка пакетов..."
wait_apt_lock
run "apt-get update -qq" || die "Не удалось обновить список пакетов"
ok "Список пакетов обновлён"

# ── 4. Установка зависимостей ────────────────────────────────────────────────
step "Установка зависимостей..."
PACKAGES=(nginx certbot python3-certbot-nginx curl dnsutils python3)
run "DEBIAN_FRONTEND=noninteractive apt-get install -y -qq ${PACKAGES[*]}" \
    || die "Не удалось установить: ${PACKAGES[*]}"
ok "Установлено: ${PACKAGES[*]}"

# ── 5. Внешний IP ────────────────────────────────────────────────────────────
step "Определение внешнего IP..."
EXTERNAL_IP=$(get_external_ip) || die "Не удалось определить внешний IP"
ok "Внешний IP: $EXTERNAL_IP"

# ── 6. DNS A-запись ──────────────────────────────────────────────────────────
step "Проверка A-записи $DOMAIN..."
DOMAIN_IP=$(dig +short A "$DOMAIN" @1.1.1.1 | grep -E '^[0-9.]+$' | head -n1)
[[ -z "$DOMAIN_IP" ]] && die "A-запись для $DOMAIN не найдена" "$GITHUB_URL"
ok "DNS A-запись: $DOMAIN_IP"

# ── 7. Сверка IP ─────────────────────────────────────────────────────────────
step "Проверка соответствия DNS ↔ IP сервера..."
[[ "$DOMAIN_IP" != "$EXTERNAL_IP" ]] \
    && die "DNS ($DOMAIN_IP) ≠ IP сервера ($EXTERNAL_IP). Обновите A-запись." "$GITHUB_URL"
ok "DNS корректен: $DOMAIN_IP = $EXTERNAL_IP"

# ── 8. Остановка nginx ───────────────────────────────────────────────────────
step "Остановка nginx..."
systemctl stop nginx 2>/dev/null || true
ok "Nginx остановлен"

# ── 9. Проверка портов ───────────────────────────────────────────────────────
step "Проверка доступности портов 80/443..."
check_port_free 80
check_port_free 443
ok "Порты 80 и 443 свободны"

# ── 10. AI генерация сайта ───────────────────────────────────────────────────
step "Генерация сайта через AI (тема: \"$SITE_THEME\")..."
echo -e "\n  ${CYAN}Запрос отправлен. AI думает — это может занять до 10 минут.${NC}"

AI_HTML_FILE=$(mktemp /tmp/ai_site_XXXXXX.html)
FALLBACK_USED=false

generate_ai_site "$SITE_THEME" "$AI_HTML_FILE" &
AI_PID=$!
spinner "$AI_PID"
wait "$AI_PID" && AI_OK=true || AI_OK=false

if $AI_OK && [[ -s "$AI_HTML_FILE" ]]; then
    rm -rf "${WEBROOT:?}"/*
    cp "$AI_HTML_FILE" "$WEBROOT/index.html"
    chmod 644 "$WEBROOT/index.html"
    HTML_SIZE=$(wc -c < "$WEBROOT/index.html")
    ok "AI сайт сгенерирован и установлен (${HTML_SIZE} байт)"
else
    warn "AI вернул некорректный ответ — используется страница-заглушка"
    FALLBACK_USED=true
    cat > "$WEBROOT/index.html" <<'FALLBACK'
<!DOCTYPE html>
<html lang="ru">
<head>
<meta charset="utf-8"/>
<meta name="viewport" content="width=device-width,initial-scale=1"/>
<title>Welcome</title>
<style>
  *{margin:0;padding:0;box-sizing:border-box}
  body{
    min-height:100vh;display:flex;align-items:center;justify-content:center;
    background:linear-gradient(135deg,#0b1120,#1a2340);
    font-family:system-ui,sans-serif;color:#e2e8f0;
  }
  .card{
    text-align:center;padding:48px 40px;
    background:rgba(255,255,255,.05);
    border:1px solid rgba(255,255,255,.1);
    border-radius:16px;
    animation:fadeIn .8s ease;
  }
  h1{font-size:2rem;margin-bottom:12px}
  p{color:#94a3b8}
  @keyframes fadeIn{
    from{opacity:0;transform:translateY(20px)}
    to{opacity:1;transform:none}
  }
</style>
</head>
<body>
  <div class="card">
    <h1>🚀 Server is running</h1>
    <p>Configured successfully.</p>
  </div>
</body>
</html>
FALLBACK
fi
rm -f "$AI_HTML_FILE"

# ── 11. SSL сертификат ───────────────────────────────────────────────────────
step "Получение SSL сертификата..."
run "certbot certonly --standalone -d $DOMAIN --agree-tos -m $LE_EMAIL --non-interactive" \
    || die "Не удалось получить SSL. Проверьте DNS и порты." "$GITHUB_URL"
ok "SSL сертификат получен"
setup_certbot_renewal

# ── 12. Конфиг Nginx ─────────────────────────────────────────────────────────
step "Создание конфигурации Nginx..."
CONF_PATH="$NGINX_CONF_DIR/sni_${DOMAIN}.conf"
write_nginx_config "$DOMAIN" "$SPORT" "$CONF_PATH"
rm -f "$NGINX_CONF_DIR/default"
ok "Конфиг записан: $CONF_PATH"

# ── 13. Nginx тест + запуск ──────────────────────────────────────────────────
step "Запуск Nginx..."
nginx -t >> "$LOG_FILE" 2>&1 \
    || die "Конфигурация Nginx содержит ошибки. Лог: $LOG_FILE"
systemctl enable --now nginx >> "$LOG_FILE" 2>&1 \
    || die "Не удалось запустить Nginx. Лог: $LOG_FILE"
ok "Nginx запущен и добавлен в автозагрузку"

# ── 14. Финальная проверка ───────────────────────────────────────────────────
step "Финальная проверка сервера..."
sleep 1
if curl -sk --max-time 5 "https://127.0.0.1:$SPORT" -H "Host: $DOMAIN" -o /dev/null; then
    ok "Сервер отвечает на 127.0.0.1:$SPORT"
else
    warn "Сервер не ответил на тестовый запрос (возможно, нужен proxy_protocol)"
fi

# ─── Итог ─────────────────────────────────────────────────────────────────────
echo ""
echo -e "${CYAN}╔═════════════════════════════════════════════════════╗${NC}"
echo -e "${CYAN}║              Установка завершена!                   ║${NC}"
echo -e "${CYAN}╚═════════════════════════════════════════════════════╝${NC}"
echo ""
echo -e "${GREEN}Параметры подключения:${NC}"
echo -e "${BLUE}──────────────────────────────────────────────────────${NC}"
echo -e " ${YELLOW}SNI домен:${NC}    $DOMAIN"
echo -e " ${YELLOW}Dest:${NC}         127.0.0.1:$SPORT"
echo -e " ${YELLOW}Сертификат:${NC}   /etc/letsencrypt/live/$DOMAIN/fullchain.pem"
echo -e " ${YELLOW}Ключ:${NC}         /etc/letsencrypt/live/$DOMAIN/privkey.pem"
echo -e " ${YELLOW}Тема сайта:${NC}   $SITE_THEME"
if $FALLBACK_USED; then
    echo -e " ${YELLOW}Сайт:${NC}         заглушка (AI недоступен)"
else
    echo -e " ${YELLOW}Сайт:${NC}         AI-сгенерирован ✓"
fi
echo -e " ${YELLOW}Лог:${NC}          $LOG_FILE"
echo -e "${BLUE}──────────────────────────────────────────────────────${NC}"
echo ""
