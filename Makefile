# ─── GT100 + EMQX Stack ──────────────────────────────────────────────────────
# Uso: make <comando>
# Se precisar de sudo para docker: make DOCKER="sudo docker" up
# ─────────────────────────────────────────────────────────────────────────────

SHELL := /bin/bash
.SHELLFLAGS := -c

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

test-mqtt: ## Publica mensagem de teste simples no broker
	@echo "📤 Publicando em test/ping..."
	mosquitto_pub -h localhost -p 1883 \
		-u "$(MQTT_USER)" -P "$(MQTT_PASS)" \
		-t "test/ping" \
		-m '{"source":"makefile","ok":true}' -d

publish: ## Publica uma medição elétrica simulada do MMW03 (uso: make publish ou make publish TOPIC=sensor/power)
	$(eval TOPIC ?= wnology/gt100-poc-01/state)
	@echo "📤 Publicando em $(TOPIC)..."
	@mosquitto_pub -h localhost -p 1883 \
		-u "$(MQTT_USER)" -P "$(MQTT_PASS)" \
		-t "$(TOPIC)" \
		-m '{ \
			"data": { \
				"v_med":   220.5, \
				"i_tot":   10.2, \
				"p_tot":   2250.0, \
				"q_tot":   450.0, \
				"s_tot":   2295.0, \
				"fp_med":  0.98, \
				"thdv_tot":2.1, \
				"thdi_tot":3.4, \
				"l1_v":    219.8, \
				"l1_i":    3.4, \
				"l1_p":    748.0, \
				"l1_f":    60.0, \
				"l2_v":    220.1, \
				"l2_i":    3.4, \
				"l2_p":    748.0, \
				"l2_f":    60.0, \
				"l3_v":    221.6, \
				"l3_i":    3.4, \
				"l3_p":    754.0, \
				"l3_f":    60.0 \
			} \
		}' && echo "✅ Mensagem enviada!"

publish-loop: ## Envia medições a cada 5s simulando o GT100 (Ctrl+C para parar)
	$(eval TOPIC ?= wnology/gt100-poc-01/state)
	$(eval INTERVAL ?= 5)
	@echo "🔁 Enviando para $(TOPIC) a cada $(INTERVAL)s — Ctrl+C para parar"
	@while true; do \
		L1V=$$(LC_NUMERIC=C awk "BEGIN{printf \"%.1f\", 218 + $$RANDOM % 5}"); \
		L2V=$$(LC_NUMERIC=C awk "BEGIN{printf \"%.1f\", 218 + $$RANDOM % 5}"); \
		L3V=$$(LC_NUMERIC=C awk "BEGIN{printf \"%.1f\", 218 + $$RANDOM % 5}"); \
		L1I=$$(LC_NUMERIC=C awk "BEGIN{printf \"%.2f\", 3 + $$RANDOM % 2}"); \
		L2I=$$(LC_NUMERIC=C awk "BEGIN{printf \"%.2f\", 3 + $$RANDOM % 2}"); \
		L3I=$$(LC_NUMERIC=C awk "BEGIN{printf \"%.2f\", 3 + $$RANDOM % 2}"); \
		L1P=$$(LC_NUMERIC=C awk "BEGIN{printf \"%.1f\", $$L1V * $$L1I * 0.98}"); \
		L2P=$$(LC_NUMERIC=C awk "BEGIN{printf \"%.1f\", $$L2V * $$L2I * 0.98}"); \
		L3P=$$(LC_NUMERIC=C awk "BEGIN{printf \"%.1f\", $$L3V * $$L3I * 0.98}"); \
		ITOT=$$(LC_NUMERIC=C awk "BEGIN{printf \"%.2f\", $$L1I + $$L2I + $$L3I}"); \
		PTOT=$$(LC_NUMERIC=C awk "BEGIN{printf \"%.1f\", $$L1P + $$L2P + $$L3P}"); \
		VMED=$$(LC_NUMERIC=C awk "BEGIN{printf \"%.1f\", ($$L1V + $$L2V + $$L3V) / 3}"); \
		QTOT=$$(LC_NUMERIC=C awk "BEGIN{printf \"%.1f\", $$PTOT * 0.2}"); \
		STOT=$$(LC_NUMERIC=C awk "BEGIN{printf \"%.1f\", $$PTOT * 1.02}"); \
		THDV=$$(LC_NUMERIC=C awk "BEGIN{printf \"%.1f\", 1.5 + $$RANDOM % 2}"); \
		THDI=$$(LC_NUMERIC=C awk "BEGIN{printf \"%.1f\", 2.0 + $$RANDOM % 3}"); \
		mosquitto_pub -h localhost -p 1883 \
			-u "$(MQTT_USER)" -P "$(MQTT_PASS)" \
			-t "$(TOPIC)" \
			-m "{\"data\":{\"v_med\":$$VMED,\"i_tot\":$$ITOT,\"p_tot\":$$PTOT,\"q_tot\":$$QTOT,\"s_tot\":$$STOT,\"fp_med\":0.98,\"thdv_tot\":$$THDV,\"thdi_tot\":$$THDI,\"l1_v\":$$L1V,\"l1_i\":$$L1I,\"l1_p\":$$L1P,\"l1_f\":60.0,\"l2_v\":$$L2V,\"l2_i\":$$L2I,\"l2_p\":$$L2P,\"l2_f\":60.0,\"l3_v\":$$L3V,\"l3_i\":$$L3I,\"l3_p\":$$L3P,\"l3_f\":60.0}}" \
			&& echo "$$(date '+%H:%M:%S') → v_med=$$VMED i_tot=$$ITOT p_tot=$$PTOT"; \
		sleep $(INTERVAL); \
	done

publish-fast: ## Publica a 100 msg/s usando conexão MQTT persistente (uso: make publish-fast ou make publish-fast MQTT_RATE=50)
	@python3 -c "import paho.mqtt.client" 2>/dev/null || pip install --quiet paho-mqtt
	@MQTT_RATE=$(or $(MQTT_RATE),100) python3 scripts/publish-fast.py

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
