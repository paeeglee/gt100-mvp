# Design Spec — Ambiente de Validação GT100 + EMQX: Production-Ready Docker Compose

| Campo | Valor |
|---|---|
| **Data** | 2026-05-28 |
| **Status** | Aprovado |
| **Referência** | PRD_Ambiente_Validacao_GT100_MMW03_EMQX.md |

---

## 1. Objetivo

Criar um ambiente production-ready em Docker Compose para receber dados MQTT do gateway WEG GT100, com:

- Broker EMQX 5.x com autenticação por usuário/senha
- TLS automático via Let's Encrypt (Traefik como terminador TLS)
- Domínio configurável via variável de ambiente (suporte a domínio dinâmico)
- Stack de monitoramento TIG: Telegraf + InfluxDB 2.x + Grafana
- README com passo a passo de produção

---

## 2. Estrutura de Arquivos

```
gt-100/
├── .env.example
├── docker-compose.yml
├── traefik/
│   └── traefik.yml
├── emqx/
│   └── emqx.conf
├── telegraf/
│   └── telegraf.conf
├── grafana/
│   └── provisioning/
│       ├── datasources/
│       │   └── influxdb.yml
│       └── dashboards/
│           └── dashboard.yml
└── README.md
```

---

## 3. Serviços e Docker Compose Profiles

| Serviço | Profile | Imagem | Responsabilidade |
|---|---|---|---|
| `traefik` | `core` | `traefik:v3` | Reverse proxy, TLS termination, ACME Let's Encrypt |
| `emqx` | `core` | `emqx/emqx:5-latest` | Broker MQTT — recebe publicações do GT100 |
| `influxdb` | `monitoring` | `influxdb:2.7` | Time-series storage das mensagens MQTT |
| `telegraf` | `monitoring` | `telegraf:1.33` | Subscriber MQTT → escritor InfluxDB |
| `grafana` | `monitoring` | `grafana/grafana:11` | Dashboards de visualização |

### Comandos de operação

```bash
# Apenas broker (fases F1–F4 do PRD)
docker compose --profile core up -d

# Adicionar monitoramento sem derrubar EMQX
docker compose --profile monitoring up -d

# Stack completo
docker compose --profile core --profile monitoring up -d
```

---

## 4. Roteamento e TLS

```
Internet
   │
   ├── :80    HTTP      → redirect HTTPS + ACME HTTP-01 challenge
   ├── :443   HTTPS     → Grafana (:3000)
   ├── :18083 HTTPS     → EMQX Dashboard (:18083 interno)
   ├── :8883  TCP TLS   → EMQX :1883 (plain na rede interna)
   └── :1883  TCP plain → EMQX :1883 (acesso LAN sem TLS)
```

> Dashboard e Grafana usam portas dedicadas em vez de path-based routing — o EMQX Dashboard não suporta subpath e path-stripping adiciona complexidade desnecessária.

### Traefik — roteamento por serviço

| Entrypoint | Protocolo | Destino interno | Observação |
|---|---|---|---|
| `:80` | HTTP | — | Redirect para HTTPS + ACME challenge |
| `:443` | HTTPS | Grafana `:3000` | Cert Let's Encrypt |
| `:18083` | HTTPS | EMQX `:18083` | Mesmo cert Let's Encrypt via SAN |
| `:8883` | TCP TLS | EMQX `:1883` | TLS terminado no Traefik |
| `:1883` | TCP plain | EMQX `:1883` | Para acesso na LAN sem TLS |

### Let's Encrypt

- **Resolver ACME**: HTTP-01 challenge na porta 80
- **Storage**: volume `traefik-certs` (`/letsencrypt/acme.json`)
- **Renovação automática**: gerenciada pelo Traefik (cert renova antes de expirar)
- **Domínio dinâmico**: alterar `DOMAIN` no `.env` + `docker compose restart traefik` solicita novo cert
- **Staging**: `LETSENCRYPT_STAGING=true` usa CA de homologação para evitar rate-limit durante testes

---

## 5. Redes Docker

| Rede | Tipo | Serviços conectados |
|---|---|---|
| `traefik-public` | bridge externo | Traefik + EMQX + Grafana |
| `monitoring` | bridge interno | EMQX + Telegraf + InfluxDB + Grafana |

EMQX está em ambas as redes: exposto ao Traefik pela `traefik-public` e acessível ao Telegraf pela `monitoring`.

---

## 6. Volumes

| Volume | Usado por | Conteúdo |
|---|---|---|
| `traefik-certs` | Traefik | `acme.json` com certificados Let's Encrypt |
| `emqx-data` | EMQX | Dados persistentes (auth, sessions, retained) |
| `emqx-log` | EMQX | Logs do broker |
| `influxdb-data` | InfluxDB | Series temporais das mensagens MQTT |
| `influxdb-config` | InfluxDB | Configuração do InfluxDB |
| `grafana-data` | Grafana | Dashboards, usuários, alertas |

---

## 7. Variáveis de Ambiente (`.env.example`)

```dotenv
# === DOMÍNIO ===
DOMAIN=mqtt.suaempresa.com.br
LETSENCRYPT_EMAIL=seu@email.com
LETSENCRYPT_STAGING=false        # true durante testes com troca de domínio

# === EMQX ===
EMQX_MQTT_USER=gt100-validacao
EMQX_MQTT_PASSWORD=troque-aqui

# === INFLUXDB ===
INFLUXDB_ORG=iot
INFLUXDB_BUCKET=emqx_data
INFLUXDB_ADMIN_USER=admin
INFLUXDB_ADMIN_PASSWORD=troque-aqui
INFLUXDB_ADMIN_TOKEN=troque-por-token-forte-aqui

# === GRAFANA ===
GF_ADMIN_USER=admin
GF_ADMIN_PASSWORD=troque-aqui
```

---

## 8. EMQX — Configuração Mínima de Produção

- **Autenticação**: mecanismo `built_in_database` (usuário/senha)
- **Usuário do GT100**: `EMQX_MQTT_USER` com permissão de PUBLISH em `#`
- **ACL**: permissão de PUBLISH irrestrita na fase de descoberta; restringir após mapeamento de tópicos
- **QoS**: 0 e 1 (conforme spec WEGnology)
- **Retained messages**: desabilitado (GT100 não suporta)
- **Dashboard**: acessível via Traefik HTTPS em `https://DOMAIN:18083`

---

## 9. Telegraf — Coleta MQTT → InfluxDB

- **Input**: `inputs.mqtt_consumer` assinando tópico `#` no EMQX interno (`:1883`, sem TLS)
- **Output**: `outputs.influxdb_v2` usando token e org do InfluxDB
- **Parsing**: `data_format = "json"` (payload do GT100 é JSON)
- **Measurement**: nome derivado do tópico MQTT (campo `topic_tag`)

---

## 10. Grafana — Provisionamento Automático

- **Datasource**: InfluxDB 2.x pré-provisionado via `provisioning/datasources/influxdb.yml`
- **Dashboard**: loader configurado via `provisioning/dashboards/dashboard.yml`
- **Acesso**: `https://DOMAIN` via Traefik (porta 443)

---

## 11. Critérios de Aceitação do Ambiente

1. `docker compose --profile core up -d` sobe Traefik + EMQX sem erros.
2. `https://DOMAIN:18083` carrega o EMQX Dashboard com cert válido.
3. GT100 conecta em `DOMAIN:8883` com TLS e aparece como cliente conectado no EMQX.
4. `docker compose --profile monitoring up -d` sobe TIG sem derrubar EMQX.
5. Telegraf aparece como cliente conectado no EMQX e escreve dados no InfluxDB.
6. Grafana em `https://DOMAIN` exibe datasource InfluxDB funcionando.
7. Troca de `DOMAIN` + restart do Traefik gera novo certificado automaticamente.

---

## 12. Decisões e Justificativas

| Decisão | Alternativa descartada | Motivo |
|---|---|---|
| TLS no Traefik (não no EMQX) | TLS no EMQX | Centraliza gestão de cert; EMQX não precisa recarregar cert |
| ACME HTTP-01 | DNS-01 (Cloudflare) | Sem dependência de provedor DNS externo |
| Docker profiles | Dois docker-compose.yml | Um arquivo, comandos claros por fase |
| InfluxDB 2.x | InfluxDB 1.x | API v2 com token auth; Telegraf e Grafana suportam nativamente |
| Telegraf como subscriber | Node-RED | Zero código; configuração declarativa via `telegraf.conf` |
