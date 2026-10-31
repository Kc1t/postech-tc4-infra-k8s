# Ambiente de integração ponta a ponta (precisa dos repositórios postech-tc4-* lado a lado).
.PHONY: contracts up lambdas e2e all logs down clean

# pkg/contracts (structs e JSON Schemas das mensagens) idêntico nos quatro repositórios.
contracts:
	./check-contracts.sh

up:
	docker compose up -d --build --wait

lambdas:
	./deploy-lambdas.sh

e2e:
	./e2e.sh

all: contracts up lambdas e2e

logs:
	docker compose logs -f os-service billing-service execution-service

down:
	docker compose down

clean:
	docker compose down -v --rmi local
