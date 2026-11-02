# Observabilidade como código (New Relic)

Raiz Terraform própria, separada da infra da AWS: dashboard, alertas com runbook, SLOs e o workload do sistema. Aplicada pelo workflow [`observability.yml`](../.github/workflows/observability.yml); o state fica no mesmo bucket S3 da infra, na chave `observability/prod.tfstate`.

A instrumentação fica em cada repositório: agente Go com `nrgin` nos três serviços, `nrpgx5` no Postgres do os-service e do billing, `nrawssdk-v2` no SNS, SQS e DynamoDB, `nrlambda` com a layer da extension nas três Lambdas, e o `nri-bundle` no cluster (instalado pelo [`terraform.yml`](../.github/workflows/terraform.yml)). Este diretório só transforma esses sinais em painel, alerta e SLO.

## O que é criado

| Arquivo | Recurso |
|---|---|
| `workload.tf` | Workload **Ordem de Serviço (prod)**: os três serviços (APM), as três Lambdas e o cluster, por consulta de entidade (sem GUID fixo) |
| `dashboard.tf` | Dashboard com 4 páginas: **Saga**, **Serviços**, **Mensageria e trace**, **Lambdas** |
| `alerts.tf` | Uma policy e 16 condições NRQL, cada uma com descrição e `runbook_url` para [`docs/runbooks/`](../docs/runbooks/) |
| `slo.tf` | SLOs: disponibilidade (sem 5xx) dos três serviços, latência do os-service e o de negócio da saga |
| `notifications.tf` | Destino, canal e workflow de e-mail, só quando `alert_email` não é vazio |

### Alertas

Todas as condições usam janela fechada pelo relógio (`cadence`, 2 min de atraso para o dado chegar) e fecham sozinhas depois de 30 min sem dado. A policy abre um incidente por condição e por faceta (no alerta de DLQ, um por fila).

| Condição | Limite crítico (aviso) | Runbook |
|---|---|---|
| `<serviço>: taxa de erro acima de 5% em 5 min` (3) | 5% de respostas 5xx (2,5%) | [servico-erros](../docs/runbooks/servico-erros.md) |
| `<serviço>: latência p95 acima de N s em 5 min` (3) | 1 s no os-service e no execution, 2 s no billing (metade) | [servico-latencia](../docs/runbooks/servico-latencia.md) |
| `saga: taxa de compensação acima de 30% em 30 min` | 30% das sagas encerradas (15%) | [saga-compensacao](../docs/runbooks/saga-compensacao.md) |
| `saga: saga expirada por prazo (aviso a cada uma, crítico acima de 5 em 15 min)` | mais de 5 `saga_expired` em 15 min (qualquer uma) | [saga-expirada](../docs/runbooks/saga-expirada.md) |
| `mensageria: mensagem falhou na última entrega antes da DLQ (receive_count >= 5)` | qualquer `message_failed` com `receive_count >= 5`, por consumidor | [dlq](../docs/runbooks/dlq.md) |
| `mensageria: mensagem malformada recebida em 5 min` | qualquer `message_malformed` ou `notification_invalid_*` | [mensagem-malformada](../docs/runbooks/mensagem-malformada.md) |
| `mensageria: mensagem travada no outbox` | qualquer `outbox_message_stuck` | [outbox-travado](../docs/runbooks/outbox-travado.md) |
| `lambda <issuer, authorizer, notifier>: taxa de erro acima de 5% em 5 min` (3) | 5% das invocações com erro (2,5%) | [lambda-erros](../docs/runbooks/lambda-erros.md) |
| `lambda notifier: falhas de envio de e-mail acima de 4 em 5 min` | mais de 4 falhas de envio, dedup ou template (qualquer uma) | [lambda-erros](../docs/runbooks/lambda-erros.md) |
| `lambda authorizer: mais de 50 requisições negadas em 5 min` | mais de 50 `missing_token` ou `invalid_token` (25) | [authorizer-negacoes](../docs/runbooks/authorizer-negacoes.md) |

### SLOs

Janela de 7 dias.

| SLO | Objetivo | Evento ruim |
|---|---|---|
| `<serviço>: disponibilidade (sem 5xx)` (3) | 99,5% | requisição de negócio com resposta 5xx |
| `os-service: latência abaixo de 500 ms` | 95% | requisição de negócio com duração ≥ 500 ms |
| `saga: OS encerradas sem compensação técnica` | 95% | `saga_compensated` por falha do sistema ou de dados; as falhas simuladas (`simulate_failure`) contam como técnicas, de propósito. Recusa do cliente, cancelamento pela oficina, prazo, estoque, pagamento recusado pelo provedor e falta de capacidade são negócio e não contam |

## Como aplicar

Pelo CI (push na `main` que mexa em `observability/`, ou *Run workflow*): `scripts/setup-github.sh newrelic` grava `NEW_RELIC_ACCOUNT_ID` (variável), `NEW_RELIC_API_KEY` (user key `NRAK-...`, secret) e, se informado, `NEW_RELIC_ALERT_EMAIL` no `postech-tc4-infra-k8s`. O job `validate` roda nos PRs e pushes que mexem em `observability/`; o `apply` só na `main`, com `NEW_RELIC_ACCOUNT_ID` definido e `AWS_DEPLOY_ENABLED=true`, porque o state fica no S3 do lab. Ele também precisa de `aws` e `state` do mesmo script (credenciais do lab e bucket do state). O resumo do job publica os links do dashboard, do workload e dos alertas.

Localmente:

```bash
cd observability
export NEW_RELIC_API_KEY=NRAK-...        # user key, não a license key
terraform init -backend-config="bucket=<bucket-do-state>" -backend-config="key=observability/prod.tfstate" -backend-config="region=us-east-1"
terraform plan -var-file=envs/prod.tfvars -var new_relic_account_id=<id> -var alert_email=""
```

Aplique **depois do primeiro deploy dos serviços**: o SLO de um serviço precisa da entidade APM dele, que só existe quando ele reporta. Antes disso o apply cria todo o resto e lista o serviço em `apps_sem_slo`; o apply seguinte cria o SLO que faltou.

## De onde vem cada sinal

| Sinal | Origem | Usado em |
|---|---|---|
| `Transaction` web (`WebTransaction/Go/<método> <rota>`, `http.statusCode`) | agente Go com `nrgin` nos três serviços | throughput, p95, 5xx, Apdex, SLOs |
| `Transaction` `Consume/<tipo>` (`message_type`, `message_id`, `saga_id`, `messaging.consumer`, `receive_count`, `parent.transportDuration`) | `pkg/messaging/consumer.go`, que aceita o trace dos atributos da mensagem | consumo por tipo, tempo na fila |
| `Transaction` `OutboxRelay/<tipo>` e spans `MessageBroker/<SNS\|SQS>/.../Produce/Named/<destino>` | relay do outbox (`pkg/outbox`, `outbox_relay.go` no execution) e `MessageProducerSegment` do publicador | atraso do outbox, mensagens publicadas, trace entre serviços |
| Spans `Datastore/statement/Postgres/<tabela>/<operação>` | `nrpgx5` no driver pgx do os-service e do billing | trace distribuído, service map (o RDS aparece como banco) e a aba *Databases* do APM |
| Spans `Datastore/.../DynamoDB/...` | `nrawssdk-v2` no execution-service | idem, para a tabela `executions` |
| Spans `External/<host>/...` | `pkg/httpclient` (API composition do os-service e Mercado Pago no billing) e o `RoundTripper` do issuer | latência de dependência, trace Lambda → os-service |
| `Span` com `saga_id` | atributos da transação de consumo e de relay, copiados para o span raiz | spans por saga |
| `Log` `saga_*` (`saga_state`, `os_status`, `reason`) | orquestrador da saga no os-service (`sagauc`) | página Saga, alertas de compensação e expiração, SLO de negócio |
| `Log` `message_failed` (`consumer`, `receive_count`), `message_malformed`, `outbox_publish_failed`, `outbox_message_stuck` | consumidor e relay dos três serviços | sinal da DLQ, malformadas, falhas e travamento do relay |
| `Log` dos pods | stdout JSON coletado pelo `newrelic-logging` do nri-bundle; o texto sai na chave `message` (os loggers trocam o `msg` padrão do slog, para não depender de remapeamento na ingestão), com `trace.id` e `span.id` para os logs em contexto, e os outros campos viram atributos (`container_name` identifica o serviço) | todos os widgets de log |
| `Transaction` das Lambdas (`aws.lambda.arn`, `aws.lambda.coldStart`, `auth.outcome`, `http.statusCode` no issuer) | `nrlambda` + extension com `NEW_RELIC_APM_LAMBDA_MODE=true` | página Lambdas, alertas das Lambdas |
| `Log` das Lambdas (`notification_*`, `token rejeitado`...) | extension com `NEW_RELIC_EXTENSION_SEND_FUNCTION_LOGS=true` | alertas do notifier e de malformadas, widgets da página Lambdas |
| `NotificationSent` (`status`, `serviceOrderCode`, `messageId`) | custom event da Lambda de notificação | e-mails enviados |
| `K8sDeploymentSample`, `K8sContainerSample` | nri-bundle no cluster | pods, CPU e memória |

## Decisões e limitações

- **Sinais de dentro da aplicação em vez das métricas do CloudWatch.** O Learner Lab não permite criar a role que o New Relic assume para ler o CloudWatch, então as métricas nativas de SQS, RDS, DynamoDB e Lambda não chegam ao New Relic. A cobertura vem dos próprios componentes:
  - **DLQ das filas da saga** (`os-saga-replies`, `billing-commands`, `execution-commands`): o consumidor registra `message_failed` com `receive_count`, e o alerta dispara na entrega de número `max_receive_count`, a última antes da DLQ, com um incidente por fila. O alarme `postech-tc4-prod-dlq-<fila>` do CloudWatch (`messaging.tf`) confirma a mensagem na DLQ.
  - **Fila da notificação** (`notification-os-events`): a Lambda não registra `receive_count`, então a cobertura é pelos alertas `lambda notifier: falhas de envio de e-mail`, taxa de erro da function e mensagem malformada (`notification_invalid_*`), mais o alarme do CloudWatch da DLQ.
  - **Lambdas**: invocações, erros, duração e cold start vêm do `nrlambda` em APM mode, no lugar das métricas nativas.
  - **Bancos**: o tempo e as consultas do RDS e do DynamoDB aparecem nos spans de datastore do trace.
- **Lambdas em APM mode.** As consultas usam `Transaction` com `aws.lambda.arn`. Sem `NEW_RELIC_APM_LAMBDA_MODE=true` as invocações chegariam como `AwsLambdaInvocation` e a página Lambdas ficaria vazia.
- **NRQL validado só na API.** `terraform validate` confere o schema, não a consulta. Uma NRQL inválida de alerta falha no `apply`; a de um widget só aparece como erro no próprio widget.
- **Volume baixo.** Com o tráfego da demo, percentuais (erro, compensação) oscilam muito: uma falha em duas requisições é 50%. Por isso as janelas são fechadas pelo relógio (`cadence`) e os incidentes fecham sozinhos depois de 30 min sem dado.
