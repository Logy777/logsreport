#!/bin/bash
# Usage: ./logreport_v1.sh access.log [server_ip]

LOGFILE="$1"
SERVER_IP="$2"

if [ -z "$LOGFILE" ] || [ ! -f "$LOGFILE" ]; then
    echo "Usage: $0 <logfile> [server_ip]"
    exit 1
fi

# Если IP не передан, определяем автоматически
if [ -z "$SERVER_IP" ]; then
    SERVER_IP=$(curl -s ifconfig.me || curl -s 2ip.ru)
    if [ -z "$SERVER_IP" ]; then
        echo "Не удалось определить внешний IP. Укажите его вручную."
        exit 1
    fi
fi

echo "IP сервера для анализа: $SERVER_IP"
echo

# --- Временной фильтр ---
NOW_TS=$(date +%s)
CUTOFF_TS=$((NOW_TS - 6*3600))

FILTERED=$(mktemp)
awk -v cutoff="$CUTOFF_TS" '
{
    match($0, /\[([0-9]{2}\/[A-Za-z]{3}\/[0-9]{4}:[0-9]{2}:[0-9]{2}:[0-9]{2})/, m)
    if (m[1] != "") {
        cmd = "date -d \"" m[1] "\" +%s"
        cmd | getline ts
        close(cmd)
        if (ts >= cutoff) print $0
    }
}' "$LOGFILE" > "$FILTERED"

TOTAL=$(wc -l < "$FILTERED")

echo "Общее количество запросов за последние 6 часов: $TOTAL"
echo

# --- Топ-10 IP ---
echo "Топ-10 IP:"
awk '{print $1}' "$FILTERED" | sort | uniq -c | sort -nr | head -10
echo

# --- Процент ботов ---
BOT_COUNT=$(grep -iE "bot|spider|crawl" "$FILTERED" | wc -l)
BOT_PERCENT=$((100*BOT_COUNT/TOTAL))
echo "Процент запросов от ботов: $BOT_PERCENT% ($BOT_COUNT/$TOTAL)"
echo

# --- Топ-5 ботов ---
echo "Топ-5 ботов:"
grep -iE "bot|spider|crawl" "$FILTERED" | awk -F\" '{print $6}' \
    | sort | uniq -c | sort -nr | head -5
echo

# --- Запросы от сервера ---
SELF_COUNT=$(awk -v ip="$SERVER_IP" '$1 == ip {c++} END{print c+0}' "$FILTERED")
SELF_PERCENT=$((100*SELF_COUNT/TOTAL))
echo "Процент запросов от сервера ($SERVER_IP): $SELF_PERCENT% ($SELF_COUNT/$TOTAL)"
echo

# --- Топ-10 ресурсов ---
echo "Топ-10 ресурсов:"
awk -F\" '{print $2}' "$FILTERED" | awk '{print $2}' | sort | uniq -c | sort -nr | head -10
echo

# --- Топ-5 двадцатиминутных интервалов ---
echo "Топ-5 20-минутных интервалов:"
awk '
{
    match($0, /\[([0-9]{2}\/[A-Za-z]{3}\/[0-9]{4}:[0-9]{2}:[0-9]{2})/, m)
    if (m[1] != "") {
        ts=m[1]
        split(ts, a, ":")
        hour=a[2]; minute=a[3]
        block=int(minute/20)
        key=a[1]":"hour":"(block*20)"-"(block*20+19)
        count[key]++
    }
}
END{
    for (k in count) print count[k], k
}' "$FILTERED" | sort -nr | head -5 > ~/tmp/top5.txt

cat ~/tmp/top5.txt
echo

# --- Анализ первых двух интервалов ---
i=1
while read cnt interval; do
    if [ $i -le 2 ]; then
        echo "===== Интервал $interval ($cnt запросов) ====="

        INTERVAL_LOG=$(mktemp)
        awk -v iv="$interval" '
        {
            match($0, /\[([0-9]{2}\/[A-Za-z]{3}\/[0-9]{4}:[0-9]{2}):([0-9]{2})/, m)
            if (m[1] != "" && m[2] != "") {
                block=int(m[2]/20)*20
                key=m[1]":"block"-"(block+19)
                if (key==iv) print $0
            }
        }' "$FILTERED" > "$INTERVAL_LOG"

        SUBTOTAL=$(wc -l < "$INTERVAL_LOG")

        echo "Топ-10 IP:"
        awk '{print $1}' "$INTERVAL_LOG" | sort | uniq -c | sort -nr | head -10
        echo

        BOT_COUNT=$(grep -iE "bot|spider|crawl" "$INTERVAL_LOG" | wc -l)
        BOT_PERCENT=$((100*BOT_COUNT/SUBTOTAL))
        echo "Процент запросов от ботов: $BOT_PERCENT% ($BOT_COUNT/$SUBTOTAL)"
        echo

        echo "Топ-5 ботов:"
        grep -iE "bot|spider|crawl" "$INTERVAL_LOG" | awk -F\" '{print $6}' \
            | sort | uniq -c | sort -nr | head -5
        echo

        SELF_COUNT=$(awk -v ip="$SERVER_IP" '$1 == ip {c++} END{print c+0}' "$INTERVAL_LOG")
        SELF_PERCENT=$((100*SELF_COUNT/SUBTOTAL))
        echo "Процент запросов от сервера: $SELF_PERCENT% ($SELF_COUNT/$SUBTOTAL)"
        echo

        echo "Топ-10 ресурсов:"
        awk -F\" '{print $2}' "$INTERVAL_LOG" | awk '{print $2}' | sort | uniq -c | sort -nr | head -10
        echo
        rm -f "$INTERVAL_LOG"
    fi
    i=$((i+1))
done < ~/tmp/top5.txt

rm -f "$FILTERED" ~/tmp/top5.txt

