# Runbook: mensagem travada no outbox

**Alerta:** `mensageria: mensagem travada no outbox`.
**Severidade:** alta. Uma mensagem da saga não sai do serviço que a gravou: o passo seguinte não acontece, e a saga daquela OS fica parada até expirar pelo prazo.

O que dispara: o log `outbox_message_stuck`, que o relay do outbox grava a partir da 10ª tentativa de publicação sem sucesso (uns 8 minutos falhando). Entre uma tentativa e outra a espera cresce até 5 min ([ADR-0018](https://github.com/Kc1t/postech-tc4-os-service/blob/main/docs/adr/0018-outbox-inbox-e-lock-otimista.md)), e a mensagem não ocupa o lote das outras: as demais continuam saindo.

## 1. Qual mensagem e por quê (até 10 min)

```sql
SELECT latest(timestamp), latest(attempts), latest(error), latest(destination) FROM Log
WHERE message = 'outbox_message_stuck' FACET container_name, message_id, message_type SINCE 1 hour ago

SELECT count(*) FROM Log WHERE message IN ('outbox_publish_failed', 'outbox_message_stuck')
FACET container_name, error SINCE 3 hours ago TIMESERIES
```

Nas transações `OutboxRelay/<tipo>` do APM, a falha aparece como erro com a mesma mensagem.

## 2. Causa e ação

| Erro | Causa | Ação |
|---|---|---|
| `AccessDenied`, `ExpiredToken`, `InvalidClientTokenId` | Credenciais da sessão do Learner Lab vencidas: os pods herdam a `LabRole` pelo IMDS | Nova sessão do lab e `kubectl -n postech rollout restart deploy/<serviço>`. As mensagens saem sozinhas na próxima tentativa. |
| `NotFound`, `NonExistentQueue`, `Topic does not exist` | Fila ou tópico apagado, ou URL/ARN errado no ConfigMap | `terraform apply` do infra-k8s; conferir as URLs no `k8s/configmap.yaml` do serviço contra os outputs `sqs_queue_urls` e `sns_topic_arns`. |
| `contracts: ...` (parse) | Corpo gravado fora do `outbox.Enqueue` (inserção manual) | Apagar a linha (passo 3). |
| Timeout ou erro de rede | SNS/SQS fora ou o nó sem saída | Ver o status da AWS e os eventos do nó; se for passageiro, não fazer nada: a próxima tentativa publica. |

Quando várias mensagens travam ao mesmo tempo e com o mesmo erro, a causa é de infraestrutura (credenciais ou destino), não da mensagem.

## 3. Apagar uma mensagem que não deve sair

Só depois de confirmar que ela é lixo: apagar uma mensagem válida deixa a saga parada até o prazo, que então compensa.

PostgreSQL (os-service e billing-service):

```bash
secret=postech-tc4-prod-<serviço>-db-credentials   # os-service ou billing-service
dsn=$(aws secretsmanager get-secret-value --secret-id "$secret" --query SecretString --output text | jq -r .dsn)
kubectl -n postech run psql-$RANDOM --rm -it --restart=Never --image=postgres:16-alpine -- \
  psql "$dsn" -c "DELETE FROM outbox_messages WHERE id = '<message_id>' AND published_at IS NULL"
```

DynamoDB (execution-service): a chave é `pk = OUTBOX` e `sk` é o da mensagem.

```bash
aws dynamodb query --table-name executions --key-condition-expression 'pk = :p' \
  --filter-expression 'message_id = :m' \
  --expression-attribute-values '{":p":{"S":"OUTBOX"},":m":{"S":"<message_id>"}}' --query 'Items[].sk'
aws dynamodb delete-item --table-name executions --key '{"pk":{"S":"OUTBOX"},"sk":{"S":"<sk>"}}'
```

## 4. Encerramento

- Nenhum `outbox_message_stuck` novo por 15 min e `outbox_publish_failed` de volta a zero.
- Se alguma saga ficou parada, conferir no `/details` da OS se ela andou ou se expirou e compensou.
