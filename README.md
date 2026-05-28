# GT100 + EMQX — Ambiente de Validação IoT

Stack Docker Compose production-ready para receber dados MQTT do gateway WEG GT100 via broker EMQX, com TLS automático (Let's Encrypt via Traefik) e monitoramento TIG (Telegraf + InfluxDB + Grafana).

## Arquitetura

```
GT100 ──── MQTT TLS :8883 ──► Traefik ──► EMQX ──► Telegraf ──► InfluxDB ──► Grafana
                               (TLS off)   plain     subscriber    storage     dashboards
```

## Pré-requisitos

- Docker Engine ≥ 24 com Docker Compose Plugin
- `make` instalado: `apt install make`
- `mosquitto-clients` para testes: `apt install mosquitto-clients`
- Portas **80, 443, 1883, 8883, 18083** abertas no firewall
- Domínio público resolvendo para o IP do servidor (obrigatório para Let's Encrypt)

---

## Comandos disponíveis

```bash
make help          # Lista todos os comandos
```

| Comando | O que faz |
|---|---|
| `make up` | Sobe Traefik + EMQX, aguarda healthy e provisiona usuários automaticamente |
| `make monitoring` | Sobe Telegraf + InfluxDB + Grafana |
| `make down` | Para todos os serviços (mantém dados) |
| `make restart` | Para e sobe tudo novamente |
| `make provision` | Sincroniza senha do dashboard e cria usuários MQTT |
| `make status` | Status de todos os containers |
| `make logs` | Logs de todos os serviços |
| `make logs-emqx` | Logs do EMQX |
| `make logs-traefik` | Logs do Traefik |
| `make logs-telegraf` | Logs do Telegraf |
| `make publish` | Publica uma medição elétrica simulada do MMW03 |
| `make publish-loop` | Envia medições a cada 5s simulando o GT100 (Ctrl+C para parar) |
| `make subscribe` | Assina todos os tópicos em tempo real (Ctrl+C para sair) |
| `make test-mqtt` | Publica mensagem de teste simples |
| `make clean` | ⚠️ Para tudo e apaga todos os volumes |

> Se precisar de `sudo` para docker: `make DOCKER="sudo docker" up`

---

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

> ⚠️ **Senhas:** use apenas letras, números e hífens. Evite `$ % # ^ ! &` — causam problemas no shell.
> Gere senhas seguras com: `openssl rand -hex 16`

Gerar token do InfluxDB:
```bash
openssl rand -hex 32
```

### 2. Subir o broker

```bash
make up
# ou com sudo: make DOCKER="sudo docker" up
```

O comando `make up` automaticamente:
1. Sobe Traefik + EMQX
2. Aguarda o EMQX ficar `(healthy)`
3. Sincroniza a senha do dashboard
4. Cria os usuários MQTT (`gt100-validacao` e `telegraf`)

### 3. Verificar status

```bash
make status
```

### 4. Testar MQTT

```bash
# Envia uma mensagem simples
make test-mqtt

# Envia medição elétrica simulada do MMW03
make publish

# Simula GT100 enviando continuamente a cada 5s
make publish-loop
```

Em outro terminal, para ver as mensagens chegando:

```bash
make subscribe
```

### 5. Acessar o EMQX Dashboard

Abra `https://<DOMAIN>:18083` no navegador.
Use `EMQX_DASHBOARD_USER` / `EMQX_DASHBOARD_PASSWORD`.

### 6. Subir o monitoramento (TIG)

```bash
make monitoring
```

### 7. Acessar o Grafana

Abra `https://<DOMAIN>` no navegador.
Use `GF_ADMIN_USER` / `GF_ADMIN_PASSWORD`.

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

## Expondo com ngrok

O projeto inclui `ngrok.yml.example` pré-configurado com todos os túneis.

### Configurar e subir

```bash
cp ngrok.yml.example ngrok.yml
# edite ngrok.yml e substitua SEU_AUTHTOKEN_AQUI pelo token em:
# https://dashboard.ngrok.com/get-started/your-authtoken

ngrok start --all --config ngrok.yml
```

> `ngrok.yml` está no `.gitignore` — o authtoken não será commitado.

### Após subir o ngrok

Copie o hostname do túnel `web` (ex: `abc123.ngrok-free.app`) e atualize o stack:

```bash
sed -i "s/^DOMAIN=.*/DOMAIN=abc123.ngrok-free.app/" .env
docker compose restart traefik
```

### Túneis configurados (plano free = 3 túneis ativos)

| Túnel | Porta | Uso |
|---|---|---|
| `web` | 80 | **Obrigatório** — ACME challenge Let's Encrypt. Fornece o `DOMAIN`. |
| `mqtt-tls` | 8883 | MQTT TLS para GT100 fora da LAN (`X.tcp.ngrok.io:PORTA`) |
| `emqx-dashboard` | 18083 | EMQX Dashboard em `https://DOMAIN:18083` |

> **MQTT na LAN:** conecte diretamente ao IP do servidor na porta `1883` — sem ngrok, sem limitação de domínio.

---

## Troca de domínio

```bash
sed -i "s/^DOMAIN=.*/DOMAIN=novo.dominio.com/" .env
docker compose restart traefik
```

> Para evitar rate-limit ao trocar domínio com frequência:
> `ACME_CA_SERVER=https://acme-staging-v02.api.letsencrypt.org/directory`

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

**Script `make provision` retorna erro 401:**

O EMQX 5.x só usa `EMQX_DASHBOARD__DEFAULT_PASSWORD` na primeira inicialização. Após isso a senha fica no volume. Sincronize manualmente:

```bash
# Substitua pela senha no seu .env
sudo docker exec gt-100-emqx-1 emqx ctl admins passwd admin <EMQX_DASHBOARD_PASSWORD>
make DOCKER="sudo docker" provision
```

**MQTT não conecta (CONNACK 5 — not authorized):**
- Os usuários MQTT não foram criados: rode `make provision`
- Verifique se as senhas no `.env` não têm caracteres especiais (`$ % # ^ !`)

**MQTT trava sem resposta:**
- Traefik não está encaminhando para o EMQX: `make logs-traefik`
- EMQX não está healthy: `make status`

**Let's Encrypt falha:**
- Confirmar que porta 80 está acessível: `curl -v http://<DOMAIN>/.well-known/acme-challenge/test`
- Confirmar DNS: `dig +short <DOMAIN>`
- Usar staging: `ACME_CA_SERVER=https://acme-staging-v02.api.letsencrypt.org/directory`

**Telegraf não conecta no EMQX:**
- Usuário `telegraf` não existe: `make provision`
- Ver logs: `make logs-telegraf`
