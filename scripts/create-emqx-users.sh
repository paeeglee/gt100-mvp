#!/usr/bin/env bash
set -euo pipefail

EMQX_HOST="${EMQX_HOST:?EMQX_HOST não definido}"
EMQX_ADMIN_USER="${EMQX_ADMIN_USER:?EMQX_ADMIN_USER não definido}"
EMQX_ADMIN_PASSWORD="${EMQX_ADMIN_PASSWORD:?EMQX_ADMIN_PASSWORD não definido}"
EMQX_MQTT_USER="${EMQX_MQTT_USER:?EMQX_MQTT_USER não definido}"
EMQX_MQTT_PASSWORD="${EMQX_MQTT_PASSWORD:?EMQX_MQTT_PASSWORD não definido}"
EMQX_TELEGRAF_USER="${EMQX_TELEGRAF_USER:?EMQX_TELEGRAF_USER não definido}"
EMQX_TELEGRAF_PASSWORD="${EMQX_TELEGRAF_PASSWORD:?EMQX_TELEGRAF_PASSWORD não definido}"

AUTH_ID="password_based%3Abuilt_in_database"
API="http://${EMQX_HOST}:18083/api/v5"

echo "⏳ Aguardando EMQX ficar pronto em ${EMQX_HOST}:18083..."
until curl -sf "${API}/status" | grep -q "running"; do
  echo "   ... ainda iniciando"
  sleep 3
done
echo "✅ EMQX pronto."

create_user() {
  local user="$1"
  local pass="$2"
  local response http_code

  response=$(curl -s -w "\n%{http_code}" \
    -X POST "${API}/authentication/${AUTH_ID}/users" \
    -u "${EMQX_ADMIN_USER}:${EMQX_ADMIN_PASSWORD}" \
    -H "Content-Type: application/json" \
    -d @- <<EOF
{
  "user_id": "$(printf '%s\n' "$user" | jq -Rs .)",
  "password": "$(printf '%s\n' "$pass" | jq -Rs .)"
}
EOF
  )

  http_code=$(echo "$response" | tail -1)

  if [[ "$http_code" == "201" ]]; then
    echo "✅ Usuário criado: ${user}"
  elif [[ "$http_code" == "409" ]]; then
    echo "ℹ️  Usuário já existe (idempotente): ${user}"
  else
    echo "❌ Falha ao criar usuário ${user} — HTTP ${http_code}" >&2
    exit 1
  fi
}

create_user "${EMQX_MQTT_USER}" "${EMQX_MQTT_PASSWORD}"
create_user "${EMQX_TELEGRAF_USER}" "${EMQX_TELEGRAF_PASSWORD}"

echo ""
echo "Usuários MQTT provisionados com sucesso."
