# ─── GT100 + EMQX Stack ──────────────────────────────────────────────────────
# Uso: make <comando>
# Se precisar de sudo para docker: make DOCKER="sudo docker" up
# ─────────────────────────────────────────────────────────────────────────────

DOCKER  := docker
COMPOSE := $(DOCKER) compose
ENV     := .env

# Lê valores do .env sem expansão shell (seguro para senhas com chars especiais)
_get = $(shell grep "^$(1)=" $(ENV) 2>/dev/null | head -1 | cut -d'=' -f2-)

ADMIN_PASS   := $(call _get,EMQX_DASHBOARD_PASSWORD)
MQTT_USER    := $(call _get,EMQX_MQTT_USER)
MQTT_PASS    := $(call _get,EMQX_MQTT_PASSWORD)
DOMAIN       := $(call _get,DOMAIN)
EMQX_CTL     := $(DOCKER) exec $$($(DOCKER) ps --filter "ancestor=emqx/emqx" --format "{{.Names}}" | head -1)

.PHONY: up down restart monitoring provision status logs logs-emqx logs-traefik \
        logs-telegraf test-mqtt subscribe clean help

help: ## Mostra esta ajuda
	@echo ""
	@echo "  GT100 + EMQX — comandos disponíveis:"
	@echo ""
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | \
		awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36mmake %-16s\033[0m %s\n", $$1, $$2}'
	@echo ""

# ─── Ciclo de vida ────────────────────────────────────────────────────────────

up: ## Sobe Traefik + EMQX, aguarda healthy e provisiona usuários
	@echo "🚀 Subindo stack core..."
	$(COMPOSE) --profile core up -d
	@echo "⏳ Aguardando EMQX ficar healthy..."
	@until $(EMQX_CTL) emqx ping 2>/dev/null | grep -q pong; do printf "."; sleep 3; done
	@echo ""
	@$(MAKE) --no-print-directory provision
	@echo ""
	@echo "✅ Stack core no ar!"
	@echo "   Dashboard: https://$(DOMAIN):18083"

monitoring: ## Sobe Telegraf + InfluxDB + Grafana
	@echo "📊 Subindo stack de monitoramento..."
	$(COMPOSE) --profile monitoring up -d
	@echo "✅ Monitoramento no ar!"
	@echo "   Grafana: https://$(DOMAIN)"

down: ## Para todos os serviços (mantém dados)
	$(COMPOSE) --profile core --profile monitoring down

restart: ## Para e sobe tudo novamente
	@$(MAKE) --no-print-directory down
	@$(MAKE) --no-print-directory up

# ─── Provisionamento ──────────────────────────────────────────────────────────

provision: ## Sincroniza senha do dashboard e cria usuários MQTT
	@echo "🔑 Sincronizando senha do dashboard EMQX..."
	@$(EMQX_CTL) emqx ctl admins passwd admin "$(ADMIN_PASS)"
	@echo "👥 Provisionando usuários MQTT..."
	@./scripts/create-emqx-users.sh

# ─── Observabilidade ──────────────────────────────────────────────────────────

status: ## Mostra status de todos os containers
	$(COMPOSE) ps

logs: ## Logs de todos os serviços (Ctrl+C para sair)
	$(COMPOSE) logs -f

logs-emqx: ## Logs do EMQX
	$(COMPOSE) logs -f emqx

logs-traefik: ## Logs do Traefik
	$(COMPOSE) logs -f traefik

logs-telegraf: ## Logs do Telegraf
	$(COMPOSE) logs -f telegraf

# ─── Testes MQTT ──────────────────────────────────────────────────────────────

test-mqtt: ## Publica mensagem de teste no broker (porta 1883)
	@echo "📤 Publicando em test/makefile..."
	mosquitto_pub -h localhost -p 1883 \
		-u "$(MQTT_USER)" -P "$(MQTT_PASS)" \
		-t "test/makefile" \
		-m '{"source":"makefile","ok":true}' -d

subscribe: ## Assina todos os tópicos — mostra mensagens em tempo real (Ctrl+C para sair)
	mosquitto_sub -h localhost -p 1883 \
		-u "$(MQTT_USER)" -P "$(MQTT_PASS)" \
		-t "#" -v

# ─── Limpeza ──────────────────────────────────────────────────────────────────

clean: ## ⚠️  Para tudo e APAGA todos os volumes (perde dados)
	@printf "\033[31mIsso apaga TODOS os dados (volumes). Confirme digitando 'sim': \033[0m"; \
		read confirm; \
		[ "$$confirm" = "sim" ] \
			&& $(COMPOSE) --profile core --profile monitoring down -v \
			|| echo "Cancelado."

.DEFAULT_GOAL := help
