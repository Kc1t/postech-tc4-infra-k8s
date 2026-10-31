# Runbook: saga expirada por prazo

**Alerta:** `saga: saga expirada por prazo (aviso a cada uma, crítico acima de 5 em 15 min)`.
**Severidade:** aviso para uma expiração isolada (em geral o cliente não respondeu); alta quando várias expiram juntas, porque aí o mais provável é a saga ter perdido uma resposta.

O worker `ExpireSagas` do os-service roda a cada `SAGA_TIMEOUT_CHECK_INTERVAL` (1 min) e compensa as sagas paradas além do prazo: `SAGA_APPROVAL_TIMEOUT` (72 h) esperando o cliente aprovar o orçamento e `SAGA_PAYMENT_TIMEOUT` (24 h) esperando o pagamento. A OS termina `cancelled` e o cliente recebe o e-mail de cancelamento.

## 1. Quais sagas e de que prazo (até 5 min)

```sql
SELECT timestamp, service_order_code, saga_id, os_id, reason
FROM Log WHERE message = 'saga_expired' SINCE 1 day ago LIMIT 50

SELECT count(*) FROM Log WHERE message = 'saga_expired' FACET reason SINCE 1 day ago
```

- `prazo de aprovação do orçamento expirado`: o cliente não aprovou nem recusou.
- `prazo de pagamento expirado`: o orçamento foi aprovado e o pagamento não foi confirmado.

## 2. Foi o cliente ou fomos nós?

**Aprovação:** o cliente soube do orçamento? O e-mail sai no status `awaiting_approval`:

```sql
SELECT timestamp, status FROM NotificationSent WHERE serviceOrderCode = <código da OS> SINCE 7 days ago
```

Sem e-mail de `awaiting_approval`, a notificação falhou: ver [lambda-erros.md](lambda-erros.md) e a DLQ `notification-os-events-dlq`.

**Pagamento:** o Mercado Pago avisou o billing?

```sql
SELECT timestamp, message, provider_payment_id, action FROM Log
WHERE message IN ('webhook_processed', 'webhook_signature_invalid', 'webhook_ignored', 'payment_approved', 'payment_failed', 'payment_in_analysis')
SINCE 1 day ago LIMIT 100
```

- `webhook_signature_invalid`: `MP_WEBHOOK_SECRET` diferente do configurado no Mercado Pago. Corrigir com `scripts/setup-github.sh mercadopago` e refazer o deploy do billing.
- Nenhum webhook: conferir a URL de notificação (`MP_NOTIFICATION_URL` = rota `POST /api/v1/webhooks/mercadopago` do gateway). Com o gateway fake, o pagamento só anda pelo checkout simulado.
- Pagamento aprovado depois da expiração: o orquestrador estorna sozinho (`saga_late_payment_refund`). Conferir `payment_refunded` no billing.

**Resposta perdida (várias expirações juntas):** a saga esperava uma mensagem que não chegou.

```sql
SELECT count(*) FROM Log
WHERE message IN ('message_failed', 'outbox_publish_failed', 'consumer_receive_failed', 'saga_reply_failed')
FACET container_name, message SINCE 1 day ago
```

- Mensagens na DLQ: [dlq.md](dlq.md). A expiração já compensou essas OS; o redrive da resposta antiga é descartado pelo orquestrador (`saga_reply_ignored`).
- `outbox_publish_failed`: o relay não consegue publicar no SNS/SQS (credencial da `LabRole` no nó, tópico ou fila inexistente). As mensagens ficam no outbox e saem quando a causa some.

## 3. Ação e encerramento

- A compensação já foi feita e comunicada: não há o que desfazer. Para seguir com o atendimento, a equipe abre uma OS nova.
- Se a causa foi técnica (e-mail, webhook, DLQ), corrigir e registrar no incidente quantas OS expiraram por isso.
