#!/usr/bin/env bash
set -euo pipefail

ENV_FILE="${ENV_FILE:-.env}"
AUTH_ID="password_based%3Abuilt_in_database"
CONTAINER_API="http://localhost:18083/api/v5"

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

# Obtém JWT via docker exec — acessa API interna sem expor portas
echo "🔑 Autenticando como ${EMQX_ADMIN_USER}..."
LOGIN_RESPONSE=$(docker exec "$CONTAINER" curl -s \
  -X POST "${CONTAINER_API}/login" \
  -H "Content-Type: application/json" \
  -d "{\"username\":\"${EMQX_ADMIN_USER}\",\"password\":\"${EMQX_ADMIN_PASSWORD}\"}" || true)

echo "   Resposta: ${LOGIN_RESPONSE}"

TOKEN=$(echo "$LOGIN_RESPONSE" | grep -o '"token":"[^"]*"' | cut -d'"' -f4 || true)

if [[ -z "$TOKEN" ]]; then
  echo "❌ Falha ao obter token." >&2
  echo "   Senha no .env: EMQX_DASHBOARD_PASSWORD=${EMQX_ADMIN_PASSWORD}" >&2
  echo "   Para resetar: sudo docker exec ${CONTAINER} emqx ctl admins passwd admin <nova_senha>" >&2
  exit 1
fi

create_user() {
  local user="$1"
  local pass="$2"
  local response
  response=$(docker exec "$CONTAINER" curl -s -w "%{http_code}" -o /dev/null \
    -X POST "${CONTAINER_API}/authentication/${AUTH_ID}/users" \
    -H "Authorization: Bearer ${TOKEN}" \
    -H "Content-Type: application/json" \
    -d "{\"user_id\":\"${user}\",\"password\":\"${pass}\"}")
  if [[ "$response" == "201" ]]; then
    echo "✅ Usuário criado: ${user}"
  elif [[ "$response" == "409" ]]; then
    local put_response
    put_response=$(docker exec "$CONTAINER" curl -s -w "%{http_code}" -o /dev/null \
      -X PUT "${CONTAINER_API}/authentication/${AUTH_ID}/users/${user}" \
      -H "Authorization: Bearer ${TOKEN}" \
      -H "Content-Type: application/json" \
      -d "{\"password\":\"${pass}\"}")
    if [[ "$put_response" == "200" ]]; then
      echo "✅ Senha atualizada: ${user}"
    else
      echo "❌ Falha ao atualizar senha de ${user} — HTTP ${put_response}" >&2
      exit 1
    fi
  else
    echo "❌ Falha ao criar usuário ${user} — HTTP ${response}" >&2
    exit 1
  fi
}

create_user "${EMQX_MQTT_USER}" "${EMQX_MQTT_PASSWORD}"
create_user "${EMQX_TELEGRAF_USER}" "${EMQX_TELEGRAF_PASSWORD}"

echo ""
echo "Usuários MQTT provisionados com sucesso."
