# GT100 + EMQX — Ambiente de Validação IoT

Stack Docker Compose para receber dados MQTT do gateway WEG GT100 via broker EMQX, com monitoramento TIG (Telegraf + InfluxDB + Grafana). Projetado para uso em rede local (LAN).

## Arquitetura

```
GT100 ──── MQTT :1883 ──► EMQX ──► Telegraf ──► InfluxDB ──► Grafana
                          broker    subscriber    storage     dashboards
```

## Pré-requisitos

- Docker Engine ≥ 24 com Docker Compose Plugin
- `make`: `apt install make`
- `mosquitto-clients` (testes locais): `apt install mosquitto-clients`
- `python3-paho-mqtt` (simulação a 100 msg/s): `apt install python3-paho-mqtt`

---

## Comandos disponíveis

```bash
make help          # Lista todos os comandos
```

| Comando | O que faz |
|---|---|
| `make up` | Sobe o EMQX, aguarda healthy e provisiona usuários automaticamente |
| `make monitoring` | Sobe Telegraf + InfluxDB + Grafana |
| `make down` | Para todos os serviços (mantém dados) |
| `make restart` | Para e sobe tudo novamente |
| `make provision` | Sincroniza senha do dashboard e cria/atualiza usuários MQTT |
| `make status` | Status de todos os containers |
| `make logs` | Logs de todos os serviços |
| `make logs-emqx` | Logs do EMQX |
| `make logs-telegraf` | Logs do Telegraf |
| `make publish` | Publica uma medição elétrica simulada do MMW03 |
| `make publish-loop` | Envia medições a cada 5s simulando o GT100 (Ctrl+C para parar) |
| `make publish-fast` | Envia medições a 100 msg/s com conexão persistente (Ctrl+C para parar) |
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

Edite `.env` e preencha todos os campos:

| Variável | Descrição |
|---|---|
| `EMQX_DASHBOARD_USER/PASSWORD` | Credenciais do painel web do EMQX |
| `EMQX_MQTT_USER/PASSWORD` | Credenciais do GT100 para publicar no broker |
| `EMQX_TELEGRAF_USER/PASSWORD` | Credenciais do Telegraf para assinar tópicos |
| `INFLUXDB_ADMIN_*` | Credenciais e token do InfluxDB |
| `GF_ADMIN_*` | Credenciais do Grafana |

> ⚠️ **Senhas:** use apenas letras, números e hífens. Evite `$ % # ^ ! &`.
> Gere senhas seguras com: `openssl rand -hex 16`

Gerar token do InfluxDB:
```bash
openssl rand -hex 32
```

### 2. Subir o broker

```bash
make up
```

O comando `make up` automaticamente:
1. Sobe o EMQX
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

# Simula GT100 a 100 msg/s (requer python3-paho-mqtt)
make publish-fast
```

Em outro terminal, para ver as mensagens chegando:

```bash
make subscribe
```

### 5. Acessar o EMQX Dashboard

Abra `http://<IP-DO-SERVIDOR>:18083` no navegador.
Use `EMQX_DASHBOARD_USER` / `EMQX_DASHBOARD_PASSWORD`.

### 6. Subir o monitoramento (TIG)

```bash
make monitoring
```

### 7. Acessar o Grafana

Abra `http://<IP-DO-SERVIDOR>:3000` no navegador.
Use `GF_ADMIN_USER` / `GF_ADMIN_PASSWORD`.

O dashboard **GT100 — Medições Elétricas (MMW03)** é provisionado automaticamente com tensão, corrente, potência e THD por fase.

---

## Configuração do GT100

No painel web do GT100, configure o modo **Master MQTT**:

| Campo | Valor |
|---|---|
| Broker | IP do servidor na LAN (ex: `192.168.0.10`) |
| Port | `1883` |
| User / Access Key | valor de `EMQX_MQTT_USER` |
| Password / Secret | valor de `EMQX_MQTT_PASSWORD` |

---

## Portas expostas

| Porta | Protocolo | Função |
|---|---|---|
| `1883` | MQTT TCP | Broker plain — GT100 e clientes LAN |
| `8083` | MQTT WebSocket | WebSocket Client do dashboard EMQX |
| `18083` | HTTP | EMQX Dashboard + REST API |
| `3000` | HTTP | Grafana |

---

## Solução de problemas

**`make provision` retorna erro ou senha não sincroniza:**

O EMQX só aplica `EMQX_DASHBOARD__DEFAULT_PASSWORD` na primeira inicialização. Após isso a senha fica no volume. Sincronize manualmente:

```bash
docker exec gt-100-emqx-1 emqx ctl admins passwd admin <EMQX_DASHBOARD_PASSWORD>
make provision
```

**MQTT não conecta (not authorized):**
- Os usuários MQTT não foram criados: rode `make provision`
- Verifique se as senhas no `.env` não têm caracteres especiais (`$ % # ^ !`)

**Grafana sem dados:**
- Confirme que o Telegraf está subscrito: `docker exec gt-100-emqx-1 emqx ctl clients list`
  - O campo `subscriptions` deve ser `1`
- Veja os logs do Telegraf: `make logs-telegraf`
- Confirme que o publish-loop está gerando JSON válido (ponto como decimal, não vírgula)
