#!/usr/bin/env bash
set -euo pipefail

ENV_FILE="${ENV_FILE:-.env}"
AUTH_ID="password_based%3Abuilt_in_database"

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

for var in EMQX_ADMIN_PASSWORD EMQX_MQTT_PASSWORD EMQX_TELEGRAF_PASSWORD; do
  val=$(get_env "$var")
  if [[ -z "$val" ]]; then
    echo "❌ $var não encontrado em $ENV_FILE" >&2
    exit 1
  fi
done

CONTAINER=$(docker ps --filter "ancestor=emqx/emqx" --format "{{.Names}}" | head -1)
if [[ -z "$CONTAINER" ]]; then
  echo "❌ Container EMQX não encontrado. Confirme que o stack core está rodando." >&2
  exit 1
fi

echo "⏳ Aguardando EMQX ficar pronto (container: ${CONTAINER})..."
until docker exec "$CONTAINER" emqx ping 2>/dev/null | grep -q "pong"; do
  echo "   ... ainda iniciando"
  sleep 3
done
echo "✅ EMQX pronto."
echo "📋 Admin: ${EMQX_ADMIN_USER}"

create_user() {
  local user="$1"
  local pass="$2"
  local response
  response=$(docker exec "$CONTAINER" curl -sf -w "%{http_code}" -o /dev/null \
    -X POST "http://localhost:18083/api/v5/authentication/${AUTH_ID}/users" \
    -u "${EMQX_ADMIN_USER}:${EMQX_ADMIN_PASSWORD}" \
    -H "Content-Type: application/json" \
    -d "{\"user_id\": \"${user}\", \"password\": \"${pass}\"}")
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
