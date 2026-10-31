# Ambiente de integração ponta a ponta (precisa dos repositórios postech-tc4-* lado a lado).
.PHONY: contracts up lambdas e2e all gateway demo logs down clean

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

# nginx com as rotas do API Gateway na porta 8090 (POST /auth vai para a Lambda issuer).
gateway:
	./gateway.sh up

# Roteiro do vídeo (../scripts/demo.sh) pelo gateway local: caminho feliz e as duas compensações.
demo: gateway
	GATEWAY=http://localhost:8090 ADMIN_PASSWORD=admin123 ../scripts/demo.sh tudo

logs:
	docker compose logs -f os-service billing-service execution-service

down:
	./gateway.sh down
	docker compose down

clean:
	./gateway.sh down
	docker compose down -v --rmi local
