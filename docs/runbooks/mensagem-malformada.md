# Runbook: mensagem malformada

**Alerta:** `mensageria: mensagem malformada recebida em 5 min`.
**Severidade:** alta. A mensagem não é processada em nenhuma tentativa: depois de `max_receive_count` (5) entregas ela vai para a DLQ, e a saga daquela OS para até expirar.

O que dispara:

- `message_malformed` nos três serviços (`pkg/messaging/consumer.go`): o envelope não passou no `contracts.Parse`. JSON inválido, sem `message_id` ou `type`, ou `version` maior que a que o consumidor conhece (`contracts: versão de envelope não suportada`). O log traz `consumer` (a fila) e `sqs_message_id`.
- `notification_invalid_message` e `notification_invalid_payload` na Lambda de notificação: envelope ou payload do `os.ServiceOrderStatusChanged` inválidos.

Payload inválido dentro de um envelope bom não é `message_malformed`: o handler devolve erro (o billing registra antes `payload_malformed`), o log do consumidor é `message_failed` com `error` contendo `payload inválido para <tipo>` e o caminho é o da [DLQ](dlq.md).

## 1. Qual fila e qual produtor (até 10 min)

```sql
SELECT timestamp, consumer, error, sqs_message_id FROM Log
WHERE message = 'message_malformed' SINCE 1 hour ago LIMIT 50

SELECT count(*) FROM Log WHERE message IN ('message_malformed', 'message_failed')
AND error LIKE '%contracts:%' FACET consumer, error SINCE 1 day ago
```

| Fila (`consumer`) | Quem produz |
|---|---|
| `os-saga-replies` | billing-service e execution-service (tópicos `billing-events` e `execution-events`) |
| `billing-commands` | os-service |
| `execution-commands` | os-service |
| `notification-os-events` | os-service (tópico `os-events`) |

Para ver o corpo sem consumir, use o comando do passo 1 do [dlq.md](dlq.md) na fila de origem (ou na DLQ, se já chegou lá).

## 2. Causa e ação

| Erro | Causa | Ação |
|---|---|---|
| `versão de envelope não suportada` | O produtor foi publicado com um `contracts.Version` novo antes do consumidor | Publicar o consumidor com a versão nova (ou voltar o produtor com `kubectl -n postech rollout undo deploy/<produtor>`). Depois, redrive da DLQ. |
| `envelope sem message_id ou type` | Publicação fora do `pkg/messaging` (teste manual, script) | Descobrir a origem pelo `sqs_message_id` e pelo `SenderId` da mensagem; descartar. |
| `envelope inválido` (JSON) | Corpo que não é JSON: publicação manual ou corpo corrompido. Assinatura sem raw delivery não causa este erro: o consumidor (`pkg/messaging`) e a Lambda desembrulham o invólucro do SNS | Descobrir a origem pelo `sqs_message_id`; descartar (passo 4 do [dlq.md](dlq.md)). |
| `payload inválido para <tipo>` | Campo mudou de tipo ou de nome entre produtor e consumidor | Alinhar o contrato nos dois repositórios (teste de contrato) e fazer o redrive. |

## 3. Encerramento

- Nenhum `message_malformed` novo por 15 min e a DLQ da fila vazia ou reprocessada.
- Registrar a versão de produtor e consumidor envolvidas e abrir tarefa para o teste de contrato pegar o caso.
