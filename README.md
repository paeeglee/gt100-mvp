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
