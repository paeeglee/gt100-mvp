#!/usr/bin/env bash
set -euo pipefail

ENV_FILE="${ENV_FILE:-.env}"
AUTH_ID="password_based%3Abuilt_in_database"
EMQX_API="${EMQX_API:-http://localhost:18084/api/v5}"

# Lê valor do .env sem passar pelo bash (evita expansão de $ # % etc.)
get_env() {
  grep "^${1}=" "$ENV_FILE" | head -1 | cut -d'=' -f2-
}

EMQX_ADMIN_USER=$(get_env EMQX_DASHBOARD_USER)
EMQX_ADMIN_PASSWORD=$(get_env EMQX_DASHBOARD_PASSWORD)
EMQX_MQTT_USER=$(get_env EMQX_MQTT_USER)
EMQX_MQTT_PASSWORD=$(get_env EMQX_MQTT_PASSWORD)
EMQX_TELEGRAF_USER=$(get_env EMQX_TELEGRAF_USER)
EMQX_TELEGRAF_PASSWORD=$(get_env EMQX_TELEGRAF_PASSWORD)

EMQX_ADMIN_USER="${EMQX_ADMIN_USER:-admin}"
EMQX_MQTT_USER="${EMQX_MQTT_USER:-gt100-validacao}"
EMQX_TELEGRAF_USER="${EMQX_TELEGRAF_USER:-telegraf}"

echo "⏳ Aguardando EMQX ficar pronto em ${EMQX_API}..."
until curl -sf "${EMQX_API}/status" | grep -q "running"; do
  echo "   ... ainda iniciando"
  sleep 3
done
echo "✅ EMQX pronto."

# Obtém JWT (EMQX 5.x usa token em vez de basic auth na API)
echo "🔑 Autenticando como ${EMQX_ADMIN_USER}..."
TOKEN=$(curl -sf -X POST "${EMQX_API}/login" \
  -H "Content-Type: application/json" \
  -d "{\"username\":\"${EMQX_ADMIN_USER}\",\"password\":\"${EMQX_ADMIN_PASSWORD}\"}" \
  | grep -o '"token":"[^"]*"' | cut -d'"' -f4)

if [[ -z "$TOKEN" ]]; then
  echo "❌ Falha ao obter token. Verifique EMQX_DASHBOARD_USER e EMQX_DASHBOARD_PASSWORD no .env" >&2
  exit 1
fi

create_user() {
  local user="$1"
  local pass="$2"
  local response
  response=$(curl -sf -w "%{http_code}" -o /dev/null \
    -X POST "${EMQX_API}/authentication/${AUTH_ID}/users" \
    -H "Authorization: Bearer ${TOKEN}" \
    -H "Content-Type: application/json" \
    -d "{\"user_id\":\"${user}\",\"password\":\"${pass}\"}")
  if [[ "$response" == "201" ]]; then
    echo "✅ Usuário criado: ${user}"
  elif [[ "$response" == "409" ]]; then
    echo "ℹ️  Usuário já existe (idempotente): ${user}"
  else
    echo "❌ Falha ao criar usuário ${user} — HTTP ${response}" >&2
    exit 1
  fi
}

create_user "${EMQX_MQTT_USER}" "${EMQX_MQTT_PASSWORD}"
create_user "${EMQX_TELEGRAF_USER}" "${EMQX_TELEGRAF_PASSWORD}"

echo ""
echo "Usuários MQTT provisionados com sucesso."
