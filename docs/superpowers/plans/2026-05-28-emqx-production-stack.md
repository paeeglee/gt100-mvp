# GT100/EMQX Production Stack — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Criar um stack Docker Compose production-ready com Traefik (TLS/Let's Encrypt) + EMQX 5.x + TIG (Telegraf + InfluxDB + Grafana), configurável inteiramente via `.env`, com README de operação.

**Architecture:** Traefik é o único ingress — termina TLS para MQTT (porta 8883) e HTTPS (portas 443 e 18083), emitindo certificados Let's Encrypt via HTTP-01. EMQX corre na rede interna Docker em plain MQTT. Telegraf assina todos os tópicos MQTT e escreve em InfluxDB; Grafana lê do InfluxDB. Docker Compose profiles (`core`, `monitoring`) permitem subir o broker antes do stack de monitoramento.

**Tech Stack:** Docker Compose 2.x, Traefik v3, EMQX 5-latest, Telegraf 1.33, InfluxDB 2.7, Grafana 11

---

## Mapa de Arquivos

| Arquivo | Responsabilidade |
|---|---|
| `.gitignore` | Ignora `.env`, certs, volumes locais |
| `.env.example` | Template de todas as variáveis de ambiente |
| `docker-compose.yml` | Todos os serviços com profiles core/monitoring |
| `traefik/traefik.yml` | Config estática do Traefik (entrypoints, ACME, provider) |
| `emqx/emqx.conf` | Auth built_in_database + listener TCP 1883 |
| `telegraf/telegraf.conf` | Input MQTT consumer → Output InfluxDB v2 |
| `grafana/provisioning/datasources/influxdb.yml` | Datasource InfluxDB pré-provisionado |
| `grafana/provisioning/dashboards/dashboard.yml` | Loader de dashboards do diretório |
| `scripts/create-emqx-users.sh` | Cria usuários MQTT via EMQX REST API |
| `README.md` | Passo a passo de produção |

---

## Task 1: Fundação do repositório

**Files:**
- Create: `.gitignore`
- Create: `.env.example`

- [ ] **Passo 1: Criar `.gitignore`**

```
.env
*.pem
*.crt
*.key
letsencrypt/
```

- [ ] **Passo 2: Criar `.env.example`**

```dotenv
# === DOMÍNIO E TLS ===
DOMAIN=mqtt.suaempresa.com.br
LETSENCRYPT_EMAIL=seu@email.com
# Produção (padrão):
ACME_CA_SERVER=https://acme-v02.api.letsencrypt.org/directory
# Homologação — use ao testar troca de domínio para evitar rate-limit:
# ACME_CA_SERVER=https://acme-staging-v02.api.letsencrypt.org/directory

# === EMQX DASHBOARD ===
EMQX_DASHBOARD_USER=admin
EMQX_DASHBOARD_PASSWORD=troque-aqui-por-senha-forte

# === EMQX MQTT USERS ===
EMQX_MQTT_USER=gt100-validacao
EMQX_MQTT_PASSWORD=troque-aqui-por-senha-forte
EMQX_TELEGRAF_USER=telegraf
EMQX_TELEGRAF_PASSWORD=troque-aqui-por-senha-forte

# === INFLUXDB ===
INFLUXDB_ORG=iot
INFLUXDB_BUCKET=emqx_data
INFLUXDB_ADMIN_USER=admin
INFLUXDB_ADMIN_PASSWORD=troque-aqui-por-senha-forte
# Gere com: openssl rand -hex 32
INFLUXDB_ADMIN_TOKEN=troque-aqui-por-token-forte-minimo-64-chars

# === GRAFANA ===
GF_ADMIN_USER=admin
GF_ADMIN_PASSWORD=troque-aqui-por-senha-forte
```

- [ ] **Passo 3: Verificar estrutura criada**

```bash
ls -la .gitignore .env.example
```

Esperado: ambos os arquivos listados.

- [ ] **Passo 4: Commit**

```bash
git add .gitignore .env.example
git commit -m "chore: add .gitignore and .env.example"
```

---

## Task 2: Configuração estática do Traefik

**Files:**
- Create: `traefik/traefik.yml`

- [ ] **Passo 1: Criar diretório e arquivo**

```bash
mkdir -p traefik
```

Criar `traefik/traefik.yml`:

```yaml
api:
  dashboard: false

log:
  level: INFO

entryPoints:
  web:
    address: ":80"
    http:
      redirections:
        entryPoint:
          to: websecure
          scheme: https
          permanent: true
  websecure:
    address: ":443"
  emqxdashboard:
    address: ":18083"
  mqtts:
    address: ":8883"
  mqtt:
    address: ":1883"

certificatesResolvers:
  letsencrypt:
    acme:
      storage: /letsencrypt/acme.json
      httpChallenge:
        entryPoint: web

providers:
  docker:
    exposedByDefault: false
    network: traefik-public
```

> `email` e `caServer` do ACME são injetados via env vars `TRAEFIK_CERTIFICATESRESOLVERS_LETSENCRYPT_ACME_EMAIL` e `TRAEFIK_CERTIFICATESRESOLVERS_LETSENCRYPT_ACME_CASERVER` no docker-compose, permitindo troca sem editar este arquivo.

- [ ] **Passo 2: Validar YAML**

```bash
python3 -c "import yaml; yaml.safe_load(open('traefik/traefik.yml'))" && echo "YAML válido"
```

Esperado: `YAML válido`

- [ ] **Passo 3: Commit**

```bash
git add traefik/traefik.yml
git commit -m "feat: add Traefik static config with ACME HTTP-01 and MQTT entrypoints"
```

---

## Task 3: Configuração do EMQX

**Files:**
- Create: `emqx/emqx.conf`

- [ ] **Passo 1: Criar diretório e arquivo**

```bash
mkdir -p emqx
```

Criar `emqx/emqx.conf`:

```hocon
## Autenticação: exige usuário/senha via banco interno
## Conexões anônimas são rejeitadas automaticamente
authentication = [
  {
    mechanism = password_based
    backend = built_in_database
    enable = true
  }
]

## Listener MQTT TCP (plain — TLS é terminado pelo Traefik)
listeners.tcp.default {
  bind = "0.0.0.0:1883"
  max_connections = 1024
}

## Dashboard HTTP
dashboard {
  listeners.http {
    bind = "0.0.0.0:18083"
  }
}
```

- [ ] **Passo 2: Validar HOCON minimamente**

```bash
grep -E "^(authentication|listeners|dashboard)" emqx/emqx.conf | wc -l
```

Esperado: `3` (três blocos raiz presentes).

- [ ] **Passo 3: Commit**

```bash
git add emqx/emqx.conf
git commit -m "feat: add EMQX minimal config with built-in auth and TCP listener"
```

---

## Task 4: docker-compose.yml — stack completo

**Files:**
- Create: `docker-compose.yml`

- [ ] **Passo 1: Criar `docker-compose.yml`**

```yaml
networks:
  traefik-public:
  monitoring:

volumes:
  traefik-certs:
  emqx-data:
  emqx-log:
  influxdb-data:
  influxdb-config:
  grafana-data:

services:

  # ─── CORE PROFILE ────────────────────────────────────────────────────────────

  traefik:
    image: traefik:v3
    profiles: [core]
    restart: unless-stopped
    ports:
      - "80:80"
      - "443:443"
      - "1883:1883"
      - "8883:8883"
      - "18083:18083"
    volumes:
      - /var/run/docker.sock:/var/run/docker.sock:ro
      - ./traefik/traefik.yml:/etc/traefik/traefik.yml:ro
      - traefik-certs:/letsencrypt
    environment:
      - TRAEFIK_CERTIFICATESRESOLVERS_LETSENCRYPT_ACME_EMAIL=${LETSENCRYPT_EMAIL}
      - TRAEFIK_CERTIFICATESRESOLVERS_LETSENCRYPT_ACME_CASERVER=${ACME_CA_SERVER}
    networks:
      - traefik-public

  emqx:
    image: emqx/emqx:5-latest
    profiles: [core]
    restart: unless-stopped
    depends_on:
      - traefik
    volumes:
      - ./emqx/emqx.conf:/opt/emqx/etc/emqx.conf:ro
      - emqx-data:/opt/emqx/data
      - emqx-log:/opt/emqx/log
    environment:
      - EMQX_DASHBOARD__DEFAULT_USERNAME=${EMQX_DASHBOARD_USER}
      - EMQX_DASHBOARD__DEFAULT_PASSWORD=${EMQX_DASHBOARD_PASSWORD}
      - EMQX_NODE__NAME=emqx@127.0.0.1
    networks:
      - traefik-public
      - monitoring
    healthcheck:
      test: ["CMD", "emqx", "ping"]
      interval: 10s
      timeout: 5s
      retries: 12
    labels:
      - "traefik.enable=true"
      # MQTT plain TCP (sem TLS — acesso LAN direto)
      - "traefik.tcp.routers.mqtt.rule=HostSNI(`*`)"
      - "traefik.tcp.routers.mqtt.entrypoints=mqtt"
      - "traefik.tcp.routers.mqtt.service=emqx-mqtt"
      - "traefik.tcp.services.emqx-mqtt.loadbalancer.server.port=1883"
      # MQTT TLS (Traefik termina TLS, repassa plain para EMQX)
      - "traefik.tcp.routers.mqtts.rule=HostSNI(`${DOMAIN}`)"
      - "traefik.tcp.routers.mqtts.entrypoints=mqtts"
      - "traefik.tcp.routers.mqtts.tls=true"
      - "traefik.tcp.routers.mqtts.tls.certresolver=letsencrypt"
      - "traefik.tcp.routers.mqtts.service=emqx-mqtts"
      - "traefik.tcp.services.emqx-mqtts.loadbalancer.server.port=1883"
      # EMQX Dashboard HTTPS (porta 18083)
      - "traefik.http.routers.emqx-dashboard.rule=Host(`${DOMAIN}`)"
      - "traefik.http.routers.emqx-dashboard.entrypoints=emqxdashboard"
      - "traefik.http.routers.emqx-dashboard.tls=true"
      - "traefik.http.routers.emqx-dashboard.tls.certresolver=letsencrypt"
      - "traefik.http.services.emqx-dashboard.loadbalancer.server.port=18083"

  # ─── MONITORING PROFILE ──────────────────────────────────────────────────────

  influxdb:
    image: influxdb:2.7
    profiles: [monitoring]
    restart: unless-stopped
    volumes:
      - influxdb-data:/var/lib/influxdb2
      - influxdb-config:/etc/influxdb2
    environment:
      - DOCKER_INFLUXDB_INIT_MODE=setup
      - DOCKER_INFLUXDB_INIT_USERNAME=${INFLUXDB_ADMIN_USER}
      - DOCKER_INFLUXDB_INIT_PASSWORD=${INFLUXDB_ADMIN_PASSWORD}
      - DOCKER_INFLUXDB_INIT_ORG=${INFLUXDB_ORG}
      - DOCKER_INFLUXDB_INIT_BUCKET=${INFLUXDB_BUCKET}
      - DOCKER_INFLUXDB_INIT_ADMIN_TOKEN=${INFLUXDB_ADMIN_TOKEN}
    networks:
      - monitoring
    healthcheck:
      test: ["CMD", "influx", "ping"]
      interval: 10s
      timeout: 5s
      retries: 10

  telegraf:
    image: telegraf:1.33
    profiles: [monitoring]
    restart: unless-stopped
    depends_on:
      influxdb:
        condition: service_healthy
      emqx:
        condition: service_healthy
    volumes:
      - ./telegraf/telegraf.conf:/etc/telegraf/telegraf.conf:ro
    environment:
      - EMQX_TELEGRAF_USER=${EMQX_TELEGRAF_USER}
      - EMQX_TELEGRAF_PASSWORD=${EMQX_TELEGRAF_PASSWORD}
      - INFLUXDB_ADMIN_TOKEN=${INFLUXDB_ADMIN_TOKEN}
      - INFLUXDB_ORG=${INFLUXDB_ORG}
      - INFLUXDB_BUCKET=${INFLUXDB_BUCKET}
    networks:
      - monitoring

  grafana:
    image: grafana/grafana:11
    profiles: [monitoring]
    restart: unless-stopped
    depends_on:
      influxdb:
        condition: service_healthy
    volumes:
      - grafana-data:/var/lib/grafana
      - ./grafana/provisioning:/etc/grafana/provisioning:ro
    environment:
      - GF_SECURITY_ADMIN_USER=${GF_ADMIN_USER}
      - GF_SECURITY_ADMIN_PASSWORD=${GF_ADMIN_PASSWORD}
      - INFLUXDB_ADMIN_TOKEN=${INFLUXDB_ADMIN_TOKEN}
      - INFLUXDB_ORG=${INFLUXDB_ORG}
      - INFLUXDB_BUCKET=${INFLUXDB_BUCKET}
    networks:
      - traefik-public
      - monitoring
    labels:
      - "traefik.enable=true"
      - "traefik.http.routers.grafana.rule=Host(`${DOMAIN}`)"
      - "traefik.http.routers.grafana.entrypoints=websecure"
      - "traefik.http.routers.grafana.tls=true"
      - "traefik.http.routers.grafana.tls.certresolver=letsencrypt"
      - "traefik.http.services.grafana.loadbalancer.server.port=3000"
```

- [ ] **Passo 2: Validar sintaxe do compose (sem subir serviços)**

```bash
cp .env.example .env
# Preencha .env com valores de teste antes de continuar
docker compose config --quiet && echo "Compose válido"
```

Esperado: `Compose válido` (sem erros de parsing ou variáveis ausentes).

- [ ] **Passo 3: Commit**

```bash
git add docker-compose.yml
git commit -m "feat: add full docker-compose with core and monitoring profiles"
```

---

## Task 5: Script de provisionamento de usuários EMQX

**Files:**
- Create: `scripts/create-emqx-users.sh`

- [ ] **Passo 1: Criar diretório e script**

```bash
mkdir -p scripts
```

Criar `scripts/create-emqx-users.sh`:

```bash
#!/usr/bin/env bash
set -euo pipefail

EMQX_HOST="${EMQX_HOST:-localhost}"
EMQX_ADMIN_USER="${EMQX_DASHBOARD_USER:-admin}"
EMQX_ADMIN_PASSWORD="${EMQX_DASHBOARD_PASSWORD:?EMQX_DASHBOARD_PASSWORD não definido}"
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
  local response
  response=$(curl -sf -w "%{http_code}" -o /dev/null \
    -X POST "${API}/authentication/${AUTH_ID}/users" \
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
```

- [ ] **Passo 2: Tornar executável e validar sintaxe**

```bash
chmod +x scripts/create-emqx-users.sh
bash -n scripts/create-emqx-users.sh && echo "Sintaxe OK"
```

Esperado: `Sintaxe OK`

- [ ] **Passo 3: Commit**

```bash
git add scripts/create-emqx-users.sh
git commit -m "feat: add EMQX user provisioning script"
```

---

## Task 6: Smoke test do stack core

> Executa os serviços `core` e valida conectividade. Requer `.env` preenchido, portas 80/443/1883/8883/18083 livres, e acesso à internet para Let's Encrypt.

- [ ] **Passo 1: Copiar e preencher `.env`**

```bash
cp .env.example .env
# Edite .env com: DOMAIN, LETSENCRYPT_EMAIL, senhas do EMQX e ACME_CA_SERVER
# Para testes sem domínio real, use ACME_CA_SERVER=https://acme-staging-v02.api.letsencrypt.org/directory
```

- [ ] **Passo 2: Subir stack core**

```bash
docker compose --profile core up -d
```

- [ ] **Passo 3: Aguardar EMQX saudável**

```bash
docker compose ps
```

Esperado: `emqx` com status `(healthy)` após até 2 minutos.

- [ ] **Passo 4: Verificar logs do Traefik (sem erros ACME)**

```bash
docker compose logs traefik | grep -i "acme\|error\|cert" | head -20
```

Esperado: linhas com `"Obtaining certificate"` ou `"Certificate obtained"` — sem `error`.

- [ ] **Passo 5: Provisionar usuários MQTT**

```bash
# Carrega variáveis do .env e executa o script
set -a && source .env && set +a
./scripts/create-emqx-users.sh
```

Esperado:
```
✅ EMQX pronto.
✅ Usuário criado: gt100-validacao
✅ Usuário criado: telegraf
Usuários MQTT provisionados com sucesso.
```

- [ ] **Passo 6: Testar MQTT plain na porta 1883**

```bash
# Requer mosquitto-clients: apt install mosquitto-clients
mosquitto_pub -h localhost -p 1883 \
  -u "${EMQX_MQTT_USER}" -P "${EMQX_MQTT_PASSWORD}" \
  -t "test/smoke" -m '{"smoke": true}'
```

Esperado: sem erro (exit 0). Confirmar no EMQX Dashboard → Clients que o publisher apareceu.

- [ ] **Passo 7: Testar MQTT TLS na porta 8883**

```bash
# Substitua <DOMAIN> pelo valor do .env
mosquitto_pub -h "${DOMAIN}" -p 8883 \
  -u "${EMQX_MQTT_USER}" -P "${EMQX_MQTT_PASSWORD}" \
  --capath /etc/ssl/certs \
  -t "test/tls-smoke" -m '{"tls": true}'
```

Esperado: sem erro (exit 0). Se `LETSENCRYPT_STAGING=true` adicione `--insecure` ao comando.

---

## Task 7: Configurações do stack de monitoramento

**Files:**
- Create: `telegraf/telegraf.conf`
- Create: `grafana/provisioning/datasources/influxdb.yml`
- Create: `grafana/provisioning/dashboards/dashboard.yml`

- [ ] **Passo 1: Criar `telegraf/telegraf.conf`**

```bash
mkdir -p telegraf
```

```toml
[agent]
  interval = "10s"
  round_interval = true
  metric_batch_size = 1000
  metric_buffer_limit = 10000
  flush_interval = "10s"

[[inputs.mqtt_consumer]]
  servers = ["tcp://emqx:1883"]
  topics = ["#"]
  username = "${EMQX_TELEGRAF_USER}"
  password = "${EMQX_TELEGRAF_PASSWORD}"
  client_id = "telegraf-subscriber"
  data_format = "json"
  topic_tag = "topic"
  qos = 1

[[outputs.influxdb_v2]]
  urls = ["http://influxdb:8086"]
  token = "${INFLUXDB_ADMIN_TOKEN}"
  organization = "${INFLUXDB_ORG}"
  bucket = "${INFLUXDB_BUCKET}"
```

- [ ] **Passo 2: Criar `grafana/provisioning/datasources/influxdb.yml`**

```bash
mkdir -p grafana/provisioning/datasources
```

```yaml
apiVersion: 1

datasources:
  - name: InfluxDB
    type: influxdb
    access: proxy
    url: http://influxdb:8086
    uid: influxdb-gt100
    jsonData:
      version: Flux
      organization: ${INFLUXDB_ORG}
      defaultBucket: ${INFLUXDB_BUCKET}
      tlsSkipVerify: true
    secureJsonData:
      token: ${INFLUXDB_ADMIN_TOKEN}
    isDefault: true
    editable: false
```

- [ ] **Passo 3: Criar `grafana/provisioning/dashboards/dashboard.yml`**

```bash
mkdir -p grafana/provisioning/dashboards
```

```yaml
apiVersion: 1

providers:
  - name: default
    type: file
    disableDeletion: false
    updateIntervalSeconds: 30
    options:
      path: /etc/grafana/provisioning/dashboards
```

- [ ] **Passo 4: Validar YAMLs criados**

```bash
python3 -c "
import yaml
for f in [
  'telegraf/telegraf.conf',
  'grafana/provisioning/datasources/influxdb.yml',
  'grafana/provisioning/dashboards/dashboard.yml',
]:
  # telegraf.conf é TOML, apenas verifica existência
  import os
  assert os.path.exists(f), f'Não encontrado: {f}'
  print(f'OK: {f}')
"
```

Esperado: três linhas `OK: ...`

- [ ] **Passo 5: Commit**

```bash
git add telegraf/telegraf.conf \
        grafana/provisioning/datasources/influxdb.yml \
        grafana/provisioning/dashboards/dashboard.yml
git commit -m "feat: add Telegraf, InfluxDB and Grafana provisioning configs"
```

---

## Task 8: Smoke test do stack de monitoramento

- [ ] **Passo 1: Subir stack de monitoramento**

```bash
docker compose --profile monitoring up -d
```

- [ ] **Passo 2: Aguardar todos os serviços saudáveis**

```bash
docker compose ps
```

Esperado: `influxdb` com `(healthy)`. `telegraf` e `grafana` com `Up`.

- [ ] **Passo 3: Verificar logs do Telegraf (conectou no EMQX)**

```bash
docker compose logs telegraf | grep -i "mqtt\|connect\|error" | head -20
```

Esperado: linha com `Connected to` e sem `Error`.

- [ ] **Passo 4: Publicar mensagem de teste e verificar no InfluxDB**

```bash
set -a && source .env && set +a

# Publicar mensagem de teste
mosquitto_pub -h localhost -p 1883 \
  -u "${EMQX_MQTT_USER}" -P "${EMQX_MQTT_PASSWORD}" \
  -t "sensor/power" -m '{"v_med": 220.5, "i_tot": 10.2, "p_tot": 2250.0}'

# Aguardar 15s e consultar InfluxDB
sleep 15
curl -sf "http://localhost:8086/api/v2/query?org=${INFLUXDB_ORG}" \
  -H "Authorization: Token ${INFLUXDB_ADMIN_TOKEN}" \
  -H "Content-Type: application/vnd.flux" \
  -d "from(bucket: \"${INFLUXDB_BUCKET}\") |> range(start: -1m) |> limit(n:3)" \
  | head -5
```

Esperado: resposta com dados do bucket (tabela com colunas `_time`, `_value`, `topic`).

- [ ] **Passo 5: Verificar datasource no Grafana via API**

```bash
set -a && source .env && set +a
curl -sf "http://localhost:3000/api/datasources" \
  -u "${GF_ADMIN_USER}:${GF_ADMIN_PASSWORD}" \
  | python3 -m json.tool | grep '"name"'
```

Esperado: `"name": "InfluxDB"`

---

## Task 9: README.md — guia de produção

**Files:**
- Create: `README.md`

- [ ] **Passo 1: Criar `README.md`**

```markdown
# GT100 + EMQX — Ambiente de Validação IoT

Stack Docker Compose production-ready para receber dados MQTT do gateway WEG GT100 via broker EMQX, com TLS automático (Let's Encrypt via Traefik) e monitoramento TIG (Telegraf + InfluxDB + Grafana).

## Arquitetura

```
GT100 ──── MQTT TLS :8883 ──► Traefik ──► EMQX ──► Telegraf ──► InfluxDB ──► Grafana
                               (TLS off)   plain     subscriber    storage     dashboards
```

## Pré-requisitos

- Docker Engine ≥ 24 com Docker Compose Plugin
- Portas **80, 443, 1883, 8883, 18083** abertas no firewall e no servidor
- Domínio público resolvendo para o IP do servidor (obrigatório para Let's Encrypt)
- `mosquitto-clients` para validação: `apt install mosquitto-clients`

## Passo a passo — primeira implantação

### 1. Configurar variáveis de ambiente

```bash
cp .env.example .env
```

Edite `.env` e preencha **todos** os campos:

| Variável | Descrição |
|---|---|
| `DOMAIN` | Domínio público que aponta para este servidor |
| `LETSENCRYPT_EMAIL` | E-mail para notificações de renovação de cert |
| `ACME_CA_SERVER` | URL da CA do Let's Encrypt (manter padrão em prod) |
| `EMQX_DASHBOARD_USER/PASSWORD` | Credenciais do painel web do EMQX |
| `EMQX_MQTT_USER/PASSWORD` | Credenciais do GT100 para publicar no broker |
| `EMQX_TELEGRAF_USER/PASSWORD` | Credenciais do Telegraf para assinar tópicos |
| `INFLUXDB_ADMIN_*` | Credenciais e token do InfluxDB |
| `GF_ADMIN_*` | Credenciais do Grafana |

Gerar um token forte para o InfluxDB:

```bash
openssl rand -hex 32
```

### 2. Subir o broker (Traefik + EMQX)

```bash
docker compose --profile core up -d
```

Aguardar EMQX ficar `(healthy)`:

```bash
docker compose ps
```

### 3. Provisionar usuários MQTT

Execute **uma única vez** após o primeiro start (idempotente para re-execuções):

```bash
set -a && source .env && set +a
./scripts/create-emqx-users.sh
```

### 4. Validar MQTT sem TLS (LAN)

```bash
set -a && source .env && set +a
mosquitto_pub -h localhost -p 1883 \
  -u "$EMQX_MQTT_USER" -P "$EMQX_MQTT_PASSWORD" \
  -t "test/hello" -m '{"ok": true}'
```

### 5. Validar MQTT com TLS (internet)

```bash
set -a && source .env && set +a
mosquitto_pub -h "$DOMAIN" -p 8883 \
  -u "$EMQX_MQTT_USER" -P "$EMQX_MQTT_PASSWORD" \
  --capath /etc/ssl/certs \
  -t "test/tls" -m '{"tls": true}'
```

> **Staging:** Se `ACME_CA_SERVER` aponta para a CA de homologação, adicione `--insecure` ao comando.

### 6. Acessar o EMQX Dashboard

Abra `https://<DOMAIN>:18083` no navegador.
Use as credenciais `EMQX_DASHBOARD_USER` / `EMQX_DASHBOARD_PASSWORD`.

### 7. Subir o stack de monitoramento (TIG)

```bash
docker compose --profile monitoring up -d
```

### 8. Acessar o Grafana

Abra `https://<DOMAIN>` no navegador.
Use as credenciais `GF_ADMIN_USER` / `GF_ADMIN_PASSWORD`.

Verificar datasource: **Connections → Data Sources → InfluxDB → Save & Test**.

---

## Configuração do GT100

No painel web do GT100, configure o modo **Master MQTT**:

| Campo | Valor |
|---|---|
| Broker | `<DOMAIN>` |
| Port | `8883` |
| User / Access Key | valor de `EMQX_MQTT_USER` |
| Password / Secret | valor de `EMQX_MQTT_PASSWORD` |
| Device ID | `gt100-poc-01` |
| Pooling Rate | `5000` ms |

---

## Troca de domínio

Ao receber um novo domínio (ex: novo túnel ngrok):

```bash
# 1. Atualizar .env
sed -i "s/^DOMAIN=.*/DOMAIN=novo.dominio.com/" .env

# 2. Reiniciar Traefik — solicita novo certificado automaticamente
docker compose restart traefik

# 3. Verificar nos logs
docker compose logs -f traefik | grep -i "cert\|acme"
```

> Para evitar rate-limit durante testes frequentes de troca de domínio, use a CA de homologação:
> `ACME_CA_SERVER=https://acme-staging-v02.api.letsencrypt.org/directory`

---

## Referência rápida de operação

| Ação | Comando |
|---|---|
| Status de todos os serviços | `docker compose ps` |
| Logs do EMQX | `docker compose logs -f emqx` |
| Logs do Traefik | `docker compose logs -f traefik` |
| Logs do Telegraf | `docker compose logs -f telegraf` |
| Reiniciar EMQX | `docker compose restart emqx` |
| Reiniciar Traefik (novo cert) | `docker compose restart traefik` |
| Derrubar tudo (mantém dados) | `docker compose --profile core --profile monitoring down` |
| Derrubar e apagar todos os dados | `docker compose --profile core --profile monitoring down -v` |

---

## Portas expostas

| Porta | Protocolo | Função |
|---|---|---|
| `80` | HTTP | Redirect HTTPS + ACME challenge |
| `443` | HTTPS | Grafana |
| `1883` | MQTT TCP | Broker plain (acesso LAN) |
| `8883` | MQTT TLS | Broker com TLS (GT100 e clientes externos) |
| `18083` | HTTPS | EMQX Dashboard |

---

## Solução de problemas

**EMQX não conecta no GT100:**
- Verificar se `DOMAIN:8883` está acessível: `curl -v telnet://$DOMAIN:8883`
- Verificar se o cert foi emitido: `docker compose logs traefik | grep cert`

**Telegraf não conecta no EMQX:**
- Confirmar que o usuário `telegraf` foi criado: `./scripts/create-emqx-users.sh`
- Ver logs: `docker compose logs telegraf`

**Let's Encrypt falha:**
- Confirmar que a porta 80 está acessível da internet
- Confirmar que o DNS do `DOMAIN` resolve para o IP deste servidor: `dig +short $DOMAIN`
- Usar CA de staging para testes: `ACME_CA_SERVER=https://acme-staging-v02.api.letsencrypt.org/directory`
```

- [ ] **Passo 2: Verificar que o README foi criado**

```bash
wc -l README.md
```

Esperado: mais de 100 linhas.

- [ ] **Passo 3: Commit**

```bash
git add README.md
git commit -m "docs: add production README with step-by-step deployment guide"
```

---

## Task 10: Commit final de estrutura

- [ ] **Passo 1: Verificar todos os arquivos do projeto**

```bash
find . -not -path './.git/*' -not -name '.env' | sort
```

Esperado (10 arquivos além dos de docs):
```
./.env.example
./.gitignore
./README.md
./docker-compose.yml
./emqx/emqx.conf
./grafana/provisioning/dashboards/dashboard.yml
./grafana/provisioning/datasources/influxdb.yml
./scripts/create-emqx-users.sh
./telegraf/telegraf.conf
./traefik/traefik.yml
```

- [ ] **Passo 2: Garantir que `.env` não está rastreado**

```bash
git status | grep -v ".env" | head -10
```

Esperado: `.env` **não** aparece em nenhuma das seções do `git status`.

- [ ] **Passo 3: Tag de versão**

```bash
git tag v1.0.0 -m "Production-ready EMQX + TIG stack initial release"
```
