## ─────────────────────────────────────────────────────────────────────────────
## POS Remote Control — VPS Management
## ─────────────────────────────────────────────────────────────────────────────
## Usage:  make <target>
##
## Prerequisites:  copy .env.example → .env  and fill in values
## ─────────────────────────────────────────────────────────────────────────────

.DEFAULT_GOAL := help
SHELL         := /bin/bash
-include .env
export

.PHONY: help check setup status add-device remove-device list-devices \
        restart logs backup update open-firewall certbot-renew

# ── Colours ───────────────────────────────────────────────────────────────────
BOLD  := \033[1m
CYAN  := \033[0;36m
NC    := \033[0m

help: ## Show this help
	@echo ""
	@echo -e "  $(BOLD)POS Remote Control — VPS Management$(NC)"
	@echo ""
	@echo -e "  $(CYAN)First run:$(NC)"
	@echo "    cp .env.example .env   # configure your environment"
	@echo "    make check             # verify all dependencies"
	@echo "    make setup             # initial VPS setup"
	@echo ""
	@echo -e "  $(CYAN)Commands:$(NC)"
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | \
		awk 'BEGIN {FS = ":.*?## "}; {printf "    $(CYAN)make %-18s$(NC) %s\n", $$1, $$2}'
	@echo ""

check: ## Check all required dependencies (does NOT install anything)
	@bash scripts/check-deps.sh

setup: ## Initial VPS setup — WireGuard + Guacamole + nginx + fail2ban
	@bash scripts/setup.sh

status: ## Show status of all services and connected devices
	@bash scripts/status.sh

add-device: ## Add a new POS device (generates WG peer + Guacamole connections)
	@bash scripts/add-device.sh

remove-device: ## Remove a POS device (interactive selection)
	@bash scripts/remove-device.sh

list-devices: ## List all registered POS devices with WG + VNC status
	@bash scripts/list-devices.sh

restart: ## Restart all Docker services
	@echo "Restarting Docker services..."
	@docker compose restart
	@echo "Done."

certbot-renew: ## Force certificate renewal and reload nginx
	@echo "Renewing Let's Encrypt certificate..."
	@docker exec pos-certbot certbot renew --webroot -w /var/www/certbot --quiet
	@echo "Reloading nginx..."
	@docker exec pos-nginx nginx -s reload
	@echo "Done."

logs: ## Stream recent logs from all Docker services
	@docker compose logs --tail=100 -f

backup: ## Backup Guacamole DB + WireGuard configs to ./backups/
	@bash scripts/backup.sh

update: ## Pull latest Docker images and recreate containers
	@docker compose pull
	@docker compose up -d --remove-orphans

open-firewall: ## Configure UFW rules (SSH + HTTP + HTTPS + WireGuard)
	@bash scripts/open-firewall.sh
