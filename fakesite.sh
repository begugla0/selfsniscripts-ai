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
SCRIPT_VERSION="3.0.0"
SCRIPT_NAME="Self SNI Scripts"
GITHUB_URL="https://github.com/begugla0/selfsniscripts"
LOG_FILE="/var/log/sni_setup_$(date +%Y%m%d_%H%M%S).log"
NGINX_CONF_DIR="/etc/nginx/sites-enabled"
WEBROOT="/var/www/html"
AI_API_URL="https://text.pollinations.ai/openai"

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
    local domain="$1"
    local result
    result=$(echo "$domain" | grep -cE '^([a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?\.)+[a-zA-Z]{2,}$' || true)
    if [[ "$result" -eq 0 ]]; then
        die "Некорректный формат домена: $domain"
    fi
}

validate_port() {
    local port="${1:-}"
    if [[ -z "$port" ]]; then
        die "Порт не может быть пустым"
    fi
    if ! [[ "$port" =~ ^[0-9]+$ ]]; then
        die "Порт должен быть числом: $port"
    fi
    local port_num
    port_num=$(( port + 0 )) || die "Ошибка преобразования порта"
    if [[ $port_num -lt 1 ]] || [[ $port_num -gt 65535 ]]; then
        die "Некорректный порт: $port (допустимо 1–65535)"
    fi
    if [[ $port_num -lt 1024 ]]; then
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
        ip=$(curl -s --max-time 5 "$url" 2>/dev/null | tr -d '[:space:]') || true
        [[ "$ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] && { echo "$ip"; return 0; }
    done
    return 1
}

check_port_free() {
    local port="$1"
    local result
    result=$(ss -tuln 2>/dev/null | grep -c ":${port} \|:${port}$" || true)
    if [[ "$result" -gt 0 ]]; then
        die "Порт $port занят. Освободите его перед установкой." "$GITHUB_URL"
    fi
}

# ─── AI: промт ────────────────────────────────────────────────────────────────

build_ai_prompt() {
    local theme="$1"
    cat <<EOF
IMPORTANT: Do NOT think out loud. Do NOT reason. Output ONLY the final HTML immediately.

You are an expert front-end developer. Generate a complete, production-ready single-file website for the following theme: "${theme}".

STRICT OUTPUT RULES — FOLLOW EXACTLY:
- Output ONLY the raw HTML document. Start with <!DOCTYPE html> on the very first character.
- Do NOT wrap in markdown fences.
- Do NOT add any explanation, commentary, preamble, or text outside the HTML.
- Do NOT include HTML comments.
- Do NOT think before answering. Just output HTML directly.

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

# ─── AI: попытка генерации ────────────────────────────────────────────────────

_try_generate() {
    local theme="$1"
    local output_file="$2"
    local model="$3"

    log "[$model] _try_generate START"

    local prompt
    prompt=$(build_ai_prompt "$theme") || {
        log "[$model] build_ai_prompt FAILED"
        return 1
    }
    log "[$model] prompt length: ${#prompt}"

    local payload_file response_file parse_script
    payload_file=$(mktemp /tmp/ai_payload_XXXXXX.json)
    response_file=$(mktemp /tmp/ai_response_XXXXXX.json)
    parse_script=$(mktemp /tmp/ai_parser_XXXXXX.py)

    local rand_seed=$(( RANDOM * RANDOM ))

    python3 -c "
import json, sys
prompt = sys.stdin.read()
print(json.dumps({
    'model': '$model',
    'messages': [{'role': 'user', 'content': prompt}],
    'stream': False,
    'seed': $rand_seed,
    'max_tokens': 16000
}))
" <<< "$prompt" > "$payload_file"
    local py_exit=$?
    log "[$model] payload python exit=$py_exit size=$(wc -c < "$payload_file")"

    if [[ $py_exit -ne 0 ]]; then
        log "[$model] PAYLOAD FAILED"
        rm -f "$payload_file" "$response_file" "$parse_script"
        return 1
    fi

    log "[$model] curl start..."
    curl -s --max-time 300 \
        -X POST "$AI_API_URL" \
        -H "content-type: application/json" \
        -d "@$payload_file" \
        -o "$response_file" \
        2>> "$LOG_FILE"
    local curl_exit=$?
    log "[$model] curl exit=$curl_exit response_size=$(wc -c < "$response_file" 2>/dev/null || echo 0)"

    rm -f "$payload_file"

    if [[ $curl_exit -ne 0 ]] || [[ ! -s "$response_file" ]]; then
        log "[$model] CURL FAILED or empty response"
        rm -f "$response_file" "$parse_script"
        return 1
    fi

    log "[$model] RAW (first 300): $(head -c 300 "$response_file")"

    local first_bytes
    first_bytes=$(head -c 15 "$response_file" 2>/dev/null || true)
    if [[ "$first_bytes" != *"{"* ]]; then
        log "[$model] Ответ не JSON (502/nginx error): $first_bytes"
        rm -f "$response_file" "$parse_script"
        return 1
    fi

    cat > "$parse_script" << 'PYEOF'
import sys, json, re

with open(sys.argv[1], 'r', encoding='utf-8', errors='replace') as f:
    raw = f.read()

content = ''

try:
    data = json.loads(raw)

    if 'error' in data:
        sys.stderr.write(f"API ERROR: {data.get('error','')}\n")
        sys.exit(1)

    msg = data['choices'][0]['message']
    content = (msg.get('content') or '').strip()

    if not content:
        rc = (msg.get('reasoning_content') or '').strip()
        sys.stderr.write(f"INFO: content пуст, reasoning size: {len(rc)}\n")
        if rc:
            m = re.search(r'(<!DOCTYPE\s+html[\s\S]*)', rc, re.IGNORECASE)
            if m:
                content = m.group(1).strip()
            else:
                sys.stderr.write(f"ERROR: HTML не найден в reasoning\n")
                sys.exit(1)

    if not content:
        sys.stderr.write("ERROR: content и reasoning пусты\n")
        sys.exit(1)

    tokens = data.get('usage', {}).get('completion_tokens', '?')
    sys.stderr.write(f"INFO: completion_tokens={tokens}\n")

except (json.JSONDecodeError, KeyError, IndexError, TypeError) as e:
    sys.stderr.write(f"JSON ERROR: {e}\nRAW[:200]: {raw[:200]}\n")
    sys.exit(1)

content = re.sub(r'^\s*```(?:html)?\s*\n?', '', content, flags=re.IGNORECASE)
content = re.sub(r'\n?```\s*$', '', content)
content = content.strip()

if not (content.lower().startswith('<!doctype') or re.search(r'<html[\s>]', content, re.IGNORECASE)):
    m = re.search(r'(<!DOCTYPE\s+html[\s\S]*)', content, re.IGNORECASE)
    if m:
        content = m.group(1).strip()

if not (content.lower().startswith('<!doctype') or re.search(r'<html[\s>]', content, re.IGNORECASE)):
    sys.stderr.write(f"NOT HTML: {content[:200]}\n")
    sys.exit(1)

size = len(content)
if size < 3000:
    sys.stderr.write(f"TOO SMALL: {size} bytes\n")
    sys.exit(1)

with open(sys.argv[2], 'w', encoding='utf-8') as f:
    f.write(content)
sys.stderr.write(f"OK: {size} bytes written\n")
PYEOF

    python3 "$parse_script" "$response_file" "$output_file" 2>> "$LOG_FILE" || {
        rm -f "$response_file" "$parse_script"
        log "[$model] PARSE FAILED"
        return 1
    }

    rm -f "$response_file" "$parse_script"

    if [[ ! -s "$output_file" ]]; then
        log "[$model] output_file пустой"
        return 1
    fi

    log "[$model] HTML записан: $(wc -c < "$output_file") байт"
    return 0
}

# ─── AI: перебор моделей с retry ──────────────────────────────────────────────

generate_ai_site() {
    local theme="$1"
    local output_file="$2"

    local -a models=("openai-fast" "openai" "mistral")
    local max_attempts=3
    local attempt=0

    while (( attempt < max_attempts )); do
        (( attempt++ ))
        log "Попытка $attempt/$max_attempts..."

        for model in "${models[@]}"; do
            echo -e "\r  ${BLUE}[AI]${NC} Попытка $attempt · модель: ${CYAN}${model}${NC}...                    "
            if _try_generate "$theme" "$output_file" "$model"; then
                log "Успех: попытка=$attempt модель=$model"
                echo -e "\r  ${GREEN}[AI]${NC} Готово ✓  (попытка $attempt, модель ${CYAN}${model}${NC})                    "
                return 0
            fi
            log "Модель $model не дала результат"
            sleep 2
        done

        if (( attempt < max_attempts )); then
            log "Все модели в попытке $attempt не сработали, пауза 15с..."
            echo -e "\r  ${YELLOW}[AI]${NC} Сервис недоступен, повтор через 15 сек... (попытка $attempt/$max_attempts)                    "
            sleep 15
        fi
    done

    log "Все $max_attempts попыток исчерпаны"
    return 1
}

# ─── AI: спиннер ──────────────────────────────────────────────────────────────

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
    printf "\n\n"

    while kill -0 "$pid" 2>/dev/null; do
        elapsed=$(( $(date +%s) - start_time ))
        minutes=$(( elapsed / 60 ))
        seconds=$(( elapsed % 60 ))

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

        local max_sec=600
        local pct=$(( elapsed * 100 / max_sec ))
        (( pct > 99 )) && pct=99
        local filled=$(( pct * 30 / 100 ))
        local empty=$(( 30 - filled ))

        local bar_str=""
        local i
        for (( i=0; i<filled; i++ )); do bar_str+="█"; done
        for (( i=0; i<empty;  i++ )); do bar_str+="░"; done

        local dot
        (( (frame_i / 5) % 2 == 0 )) \
            && dot="${MAGENTA}●${NC}" \
            || dot="${BLUE}○${NC}"

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

        printf "\033[2A"
        printf "\r  %b %s  ${CYAN}%s${NC}%60s\n" \
            "$dot" \
            "${frames:$((frame_i % ${#frames})):1}" \
            "$phase_label" ""
        printf "\r  ${CYAN}[${GREEN}%s${YELLOW}%s${CYAN}]${NC}  ${YELLOW}%s${NC}  ${BLUE}%s${NC}%30s\n" \
            "$bar_str" "" "$time_str" "$eta_str" ""

        frame_i=$(( frame_i + 1 ))
        sleep 0.1
    done

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

    local nginx_ver major minor
    nginx_ver=$(nginx -v 2>&1 | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1)
    major=$(echo "$nginx_ver" | cut -d. -f1)
    minor=$(echo "$nginx_ver" | cut -d. -f2)

    local http2_listen http2_directive
    if (( major > 1 || ( major == 1 && minor >= 25 ) )); then
        http2_listen="ssl"
        http2_directive="    http2 on;"
    else
        http2_listen="ssl http2"
        http2_directive=""
    fi

    log "Nginx $nginx_ver: используем '$http2_listen'"

    cat > "$conf_path" <<EOF
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
    listen 127.0.0.1:${sport} ${http2_listen};
${http2_directive}
    server_name $domain;

    ssl_certificate     /etc/letsencrypt/live/$domain/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/$domain/privkey.pem;

    ssl_protocols           TLSv1.2 TLSv1.3;
    ssl_prefer_server_ciphers on;
    ssl_ciphers             ECDHE-ECDSA-AES256-GCM-SHA384:ECDHE-RSA-AES256-GCM-SHA384:ECDHE-ECDSA-CHACHA20-POLY1305:ECDHE-RSA-CHACHA20-POLY1305;
    ssl_session_cache       shared:SSL:10m;
    ssl_session_timeout     1d;
    ssl_session_tickets     off;

    add_header Strict-Transport-Security "max-age=63072000; includeSubDomains; preload" always;
    add_header X-Frame-Options DENY always;
    add_header X-Content-Type-Options nosniff always;

    real_ip_header   proxy_protocol;
    set_real_ip_from 127.0.0.1;

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
echo -e "${CYAN}║   $SCRIPT_NAME v$SCRIPT_VERSION by begugla       ║${NC}"
echo -e "${CYAN}╚═════════════════════════════════════════════════════╝${NC}"
echo ""

require_root

step "Проверка операционной системы..."
detect_os

step "Ожидание ввода данных..."
echo ""

set +e
read -rp "  Введите доменное имя:                           " DOMAIN
read -rp "  Email для Let's Encrypt (Enter = admin@$DOMAIN): " LE_EMAIL
read -rp "  Внутренний SNI порт        (Enter = 9000):       " SPORT
echo ""
echo -e "  ${CYAN}Тематика определяет что AI сгенерирует для сайта.${NC}"
echo -e "  ${YELLOW}Примеры:${NC} ремонт квартир, юридические услуги, кофейня,"
echo -e "           IT-компания, фитнес-клуб, медицинская клиника"
echo ""
read -rp "  Тематика сайта             (Enter = IT-компания): " SITE_THEME
set -e

LE_EMAIL="${LE_EMAIL:-"admin@$DOMAIN"}"
SPORT="${SPORT:-9000}"
SITE_THEME="${SITE_THEME:-IT-компания}"

[[ -z "$DOMAIN" ]] && die "Доменное имя не может быть пустым"
validate_domain "$DOMAIN"
validate_port "$SPORT"

ok "Параметры: домен=$DOMAIN  порт=$SPORT  тема=\"$SITE_THEME\""
log "Параметры: DOMAIN=$DOMAIN LE_EMAIL=$LE_EMAIL SPORT=$SPORT SITE_THEME=$SITE_THEME"

step "Обновление списка пакетов..."
wait_apt_lock
run "apt-get update -qq" || die "Не удалось обновить список пакетов"
ok "Список пакетов обновлён"

step "Установка зависимостей..."
PACKAGES=(nginx certbot python3-certbot-nginx curl dnsutils python3)
run "DEBIAN_FRONTEND=noninteractive apt-get install -y -qq ${PACKAGES[*]}" \
    || die "Не удалось установить: ${PACKAGES[*]}"
ok "Установлено: ${PACKAGES[*]}"

step "Определение внешнего IP..."
EXTERNAL_IP=$(get_external_ip) || die "Не удалось определить внешний IP"
ok "Внешний IP: $EXTERNAL_IP"

step "Проверка A-записи $DOMAIN..."
DOMAIN_IP=$(dig +short A "$DOMAIN" @1.1.1.1 | grep -E '^[0-9.]+$' | head -n1 || true)
[[ -z "$DOMAIN_IP" ]] && die "A-запись для $DOMAIN не найдена" "$GITHUB_URL"
ok "DNS A-запись: $DOMAIN_IP"

step "Проверка соответствия DNS ↔ IP сервера..."
[[ "$DOMAIN_IP" != "$EXTERNAL_IP" ]] \
    && die "DNS ($DOMAIN_IP) ≠ IP сервера ($EXTERNAL_IP). Обновите A-запись." "$GITHUB_URL"
ok "DNS корректен: $DOMAIN_IP = $EXTERNAL_IP"

step "Остановка nginx..."
systemctl stop nginx 2>/dev/null || true
ok "Nginx остановлен"

step "Проверка доступности портов 80/443..."
check_port_free 80
check_port_free 443
ok "Порты 80 и 443 свободны"

step "Генерация сайта через AI (тема: \"$SITE_THEME\")..."
echo -e "\n  ${CYAN}Запрос отправлен. AI думает — это может занять до 5 минут.${NC}"

AI_HTML_FILE=$(mktemp /tmp/ai_site_XXXXXX.html)
FALLBACK_USED=false

set +e
generate_ai_site "$SITE_THEME" "$AI_HTML_FILE" &
AI_PID=$!
spinner "$AI_PID"
wait "$AI_PID"
AI_EXIT=$?
set -e

if [[ $AI_EXIT -eq 0 ]] && [[ -s "$AI_HTML_FILE" ]]; then
    rm -rf "${WEBROOT:?}"/*
    cp "$AI_HTML_FILE" "$WEBROOT/index.html"
    chmod 644 "$WEBROOT/index.html"
    HTML_SIZE=$(wc -c < "$WEBROOT/index.html")
    ok "AI сайт сгенерирован и установлен (${HTML_SIZE} байт)"
else
    warn "AI не дал результат — используется страница-заглушка"
    echo -e "  ${YELLOW}Подробности в логе: $LOG_FILE${NC}"
    echo -e "  ${BLUE}Последние записи лога:${NC}"
    grep -i "ai\|curl\|parse\|html\|raw\|error\|модел\|reasoning\|exit" "$LOG_FILE" 2>/dev/null \
        | tail -10 \
        | while read -r line; do
            echo -e "  ${YELLOW}→${NC} $line"
          done
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

step "Получение SSL сертификата..."
run "certbot certonly --standalone -d $DOMAIN --agree-tos -m $LE_EMAIL --non-interactive" \
    || die "Не удалось получить SSL. Проверьте DNS и порты." "$GITHUB_URL"
ok "SSL сертификат получен"
setup_certbot_renewal

step "Создание конфигурации Nginx..."
CONF_PATH="$NGINX_CONF_DIR/sni_${DOMAIN}.conf"
write_nginx_config "$DOMAIN" "$SPORT" "$CONF_PATH"
rm -f "$NGINX_CONF_DIR/default"
ok "Конфиг записан: $CONF_PATH"

step "Запуск Nginx..."
nginx -t >> "$LOG_FILE" 2>&1 \
    || die "Конфигурация Nginx содержит ошибки. Лог: $LOG_FILE"
systemctl enable --now nginx >> "$LOG_FILE" 2>&1 \
    || die "Не удалось запустить Nginx. Лог: $LOG_FILE"
ok "Nginx запущен и добавлен в автозагрузку"

step "Финальная проверка сервера..."
sleep 1
set +e
curl -sk --max-time 5 "https://127.0.0.1:$SPORT" -H "Host: $DOMAIN" -o /dev/null
CURL_EXIT=$?
set -e
if [[ $CURL_EXIT -eq 0 ]]; then
    ok "Сервер отвечает на 127.0.0.1:$SPORT"
else
    warn "Сервер не ответил на тестовый запрос (возможно, нужен proxy_protocol)"
fi

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
