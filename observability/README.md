# Observabilidade como código (New Relic)

Raiz Terraform própria, separada da infra da AWS: dashboard, alertas com runbook, SLOs e o workload do sistema. Aplicada pelo workflow [`observability.yml`](../.github/workflows/observability.yml); o state fica no mesmo bucket S3 da infra, na chave `observability/prod.tfstate`.

## O que é criado

| Arquivo | Recurso |
|---|---|
| `workload.tf` | Workload **Ordem de Serviço (prod)**: os três serviços (APM), as três Lambdas e o cluster, por consulta de entidade (sem GUID fixo) |
| `dashboard.tf` | Dashboard com 4 páginas: **Saga**, **Serviços**, **Mensageria e trace**, **Lambdas** |
| `alerts.tf` | Uma policy e 16 condições NRQL, cada uma com descrição e `runbook_url` para [`docs/runbooks/`](../docs/runbooks/) |
| `slo.tf` | SLOs: disponibilidade (sem 5xx) dos três serviços, latência do os-service (95% < 500 ms) e o de negócio da saga (OS encerradas sem compensação técnica) |
| `notifications.tf` | Destino, canal e workflow de e-mail, só quando `alert_email` não é vazio |

| Condição | Runbook |
|---|---|
| `<serviço>: taxa de erro acima de 5% em 5 min` (3) | [servico-erros](../docs/runbooks/servico-erros.md) |
| `<serviço>: latência p95 acima de N s em 5 min` (3) | [servico-latencia](../docs/runbooks/servico-latencia.md) |
| `saga: taxa de compensação acima de 30% em 30 min` | [saga-compensacao](../docs/runbooks/saga-compensacao.md) |
| `saga: saga expirada por prazo` | [saga-expirada](../docs/runbooks/saga-expirada.md) |
| `mensageria: mensagem falhou na última entrega antes da DLQ` | [dlq](../docs/runbooks/dlq.md) |
| `mensageria: mensagem malformada recebida em 5 min` | [mensagem-malformada](../docs/runbooks/mensagem-malformada.md) |
| `mensageria: mensagem travada no outbox` | [outbox-travado](../docs/runbooks/outbox-travado.md) |
| `lambda <issuer, authorizer, notifier>: taxa de erro acima de 5% em 5 min` (3) | [lambda-erros](../docs/runbooks/lambda-erros.md) |
| `lambda notifier: falhas de envio de e-mail acima de 4 em 5 min` | [lambda-erros](../docs/runbooks/lambda-erros.md) |
| `lambda authorizer: mais de 50 requisições negadas em 5 min` | [authorizer-negacoes](../docs/runbooks/authorizer-negacoes.md) |

## Como aplicar

Pelo CI (push na `main` que mexa em `observability/`, ou *Run workflow*): `scripts/setup-github.sh newrelic` grava `NEW_RELIC_ACCOUNT_ID` (variável), `NEW_RELIC_API_KEY` (user key `NRAK-...`, secret) e, se informado, `NEW_RELIC_ALERT_EMAIL` no `postech-tc4-infra-k8s`. O job `validate` roda sempre (também nos PRs que mexem em `observability/`); o `apply` só na `main`, com `NEW_RELIC_ACCOUNT_ID` definido e `AWS_DEPLOY_ENABLED=true`, porque o state fica no S3 do lab. Ele também precisa de `aws` e `state` do mesmo script (credenciais do lab e bucket do state).

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
| `Transaction` `Consume/<tipo>` (`message_type`, `message_id`, `saga_id`, `messaging.consumer`, `parent.transportDuration`) | `pkg/messaging/consumer.go`, que aceita o trace dos atributos da mensagem | consumo por tipo, tempo na fila |
| `Transaction` `OutboxRelay/<tipo>` e spans `MessageBroker/<SNS\|SQS>/.../Produce/Named/<destino>` | relay do outbox (`pkg/outbox`, `outbox_relay.go` no execution) e `MessageProducerSegment` do publicador | atraso do outbox, mensagens publicadas, trace entre serviços |
| `Span` com `saga_id` | atributos da transação de consumo e de relay, copiados para o span raiz | spans por saga |
| `Log` `saga_*` (`saga_state`, `os_status`, `reason`) | orquestrador da saga no os-service (`sagauc`) | página Saga, alertas de compensação e expiração, SLO de negócio |
| `Log` `message_failed` (`consumer`, `receive_count`), `message_malformed`, `outbox_publish_failed` | consumidor e relay dos três serviços | proxy da DLQ, malformadas, falhas do relay |
| `Log` dos pods | stdout JSON coletado pelo `newrelic-logging` do nri-bundle; o `msg` vira `message` e os campos viram atributos (`container_name` identifica o serviço) | todos os widgets de log |
| `Transaction` das Lambdas (`aws.lambda.arn`, `aws.lambda.coldStart`, `auth.outcome`) | `nrlambda` + extension com `NEW_RELIC_APM_LAMBDA_MODE=true` | página Lambdas, alertas das Lambdas |
| `NotificationSent` (`status`, `serviceOrderCode`, `messageId`) | custom event da Lambda de notificação | e-mails enviados |
| `K8sDeploymentSample`, `K8sContainerSample` | nri-bundle no cluster | pods, CPU e memória |

## Limitações

- **Learner Lab sem integração AWS.** A role que o New Relic assume para ler o CloudWatch não pode ser criada, então não chegam métricas de SQS (profundidade, idade, DLQ), RDS, DynamoDB nem as métricas nativas das Lambdas. O alarme de DLQ fica no CloudWatch (`messaging.tf`); no New Relic o alerta usa o `message_failed` na entrega de número `max_receive_count`, que só existe nos serviços: a fila da notificação depende do alarme do CloudWatch.
- **Lambdas em APM mode.** As consultas usam `Transaction` com `aws.lambda.arn`. Sem `NEW_RELIC_APM_LAMBDA_MODE=true` as invocações chegariam como `AwsLambdaInvocation` e a página Lambdas ficaria vazia.
- **Postgres sem instrumentação.** O GORM do os-service e do billing não tem segmento de datastore: o tempo de banco aparece como tempo da transação e o RDS não aparece no service map.
- **NRQL validado só na API.** `terraform validate` confere o schema, não a consulta. Uma NRQL inválida de alerta falha no `apply`; a de um widget só aparece como erro no próprio widget.
- **Volume baixo.** Com o tráfego da demo, percentuais (erro, compensação) oscilam muito: uma falha em duas requisições é 50%. Os alertas usam janelas fechadas pelo relógio (`cadence`) e fecham sozinhos depois de 30 min sem dado.
