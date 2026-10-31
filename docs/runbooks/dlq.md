# Runbook: mensagem na DLQ

**Alarme:** `postech-tc4-prod-dlq-<fila>` no CloudWatch (`ApproximateNumberOfMessagesVisible` > 0 na `<fila>-dlq`).
**No New Relic:** `mensageria: mensagem falhou na última entrega antes da DLQ (receive_count >= 5)`, um incidente por fila. O Learner Lab não permite a integração do CloudWatch com o New Relic, então o sinal é o log `message_failed` do consumidor na entrega de número `max_receive_count`: a próxima recepção move a mensagem para a DLQ. A fila da notificação só tem o alarme do CloudWatch, porque a Lambda não registra `receive_count`.
**Severidade:** alta quando a fila é da saga, média quando é a de notificação.

Uma mensagem só chega à DLQ depois de falhar `max_receive_count` vezes (5 por padrão) na fila de origem. Isso nunca é um erro passageiro: a mensagem não foi processada e algo precisa de correção.

## 1. O que cada DLQ significa

| DLQ | Consumidor | Impacto para o cliente |
|---|---|---|
| `os-saga-replies-dlq` | orquestrador da saga (os-service) | A OS para no estado atual porque o orquestrador não recebeu a resposta do billing ou do execution. Se nada for feito, o job `ExpireSagas` compensa a saga quando o prazo vence, e a OS termina `cancelled`. |
| `billing-commands-dlq` | billing-service | O orçamento não foi criado ou cancelado, ou o pagamento não foi pedido ou estornado. A saga espera e, no prazo, expira. |
| `execution-commands-dlq` | execution-service | O diagnóstico ou o reparo não entrou na fila do mecânico. |
| `notification-os-events-dlq` | Lambda `postech-tc4-prod-notifier` | O cliente não recebeu o e-mail de mudança de status. A OS segue normalmente. |

## 2. Diagnóstico (até 15 min)

1. **Ver a mensagem sem consumir** (o `--visibility-timeout 0` devolve a mensagem para a DLQ na hora):

   ```bash
   Q=os-saga-replies   # nome da fila sem o -dlq
   URL=$(aws sqs get-queue-url --queue-name "$Q-dlq" --query QueueUrl --output text)
   aws sqs receive-message --queue-url "$URL" --max-number-of-messages 10 \
     --visibility-timeout 0 --attribute-names All --message-attribute-names All \
     | jq '.Messages[] | {id: .MessageId, recebida: .Attributes.ApproximateReceiveCount, corpo: (.Body | fromjson? // .)}'
   ```

   O envelope traz `type`, `message_id`, `saga_id`, `os_id` e `correlation_id`.

2. **Achar o erro no New Relic** pelos logs em contexto, com o `message_id` ou o `saga_id` da mensagem:

   ```sql
   SELECT timestamp, container_name, consumer, message, error, receive_count
   FROM Log
   WHERE message_id = '<message_id>' OR saga_id = '<saga_id>'
   SINCE 1 day ago
   ```

   | Log | Causa provável | Ação |
   |---|---|---|
   | `message_malformed` | O corpo não segue o contrato (`pkg/contracts`), porque o produtor e o consumidor estão em versões diferentes do schema. | Publicar o consumidor compatível com a versão que o produtor manda e depois fazer o redrive. Se o corpo estiver corrompido de fato, siga o passo 4. |
   | `message_failed` + erro de banco ou de rede | Banco fora, credencial expirada no Secrets Manager, SG. | Corrigir a infraestrutura e depois fazer o redrive. |
   | `message_failed` + erro de regra (`invalid transition`, `not found`) | O estado do agregado não aceita o evento, porque ele chegou fora de ordem ou a OS foi cancelada antes. | Conferir a timeline da OS (`GET /api/v1/service-orders/{id}/details`). Se a saga já terminou, a mensagem pode ser descartada. |
   | `notification_send_failed` | SMTP (Brevo) recusou ou excedeu a cota. | Conferir as credenciais SMTP da Lambda e a cota do Brevo, depois fazer o redrive. |

3. **Ver o trace distribuído:** a transação `Consume/<type>` do consumidor carrega o trace do produtor (os headers W3C viajam nos atributos da mensagem). No New Relic, o filtro `message_id = <id>` em *Distributed tracing* mostra a requisição que originou o comando.

## 3. Correção e redrive

O redrive é seguro porque **todos os consumidores são idempotentes**. Cada um registra o `message_id` processado num inbox: a tabela `processed_messages` no os-service e no billing-service, o item `MSG#<consumidor>#<message_id>` na tabela `executions` do execution-service e a tabela de dedup da Lambda. Uma mensagem já processada é descartada sem efeito.

Depois de corrigir a causa:

```bash
DLQ_ARN=$(aws sqs get-queue-attributes --queue-url "$URL" --attribute-names QueueArn --query Attributes.QueueArn --output text)
aws sqs start-message-move-task --source-arn "$DLQ_ARN"            # devolve para a fila de origem
aws sqs list-message-move-tasks --source-arn "$DLQ_ARN" --max-results 1   # acompanhar
```

Para devolver aos poucos, use `--max-number-of-messages-per-second 5`.

## 4. Quando não dá para reprocessar

- **Corpo corrompido** (nenhuma versão do consumidor aceita): descartar com `aws sqs delete-message` depois de registrar o `message_id` no incidente. Se o evento fazia falta, a saga fica parada até o `ExpireSagas` compensar no prazo. Para destravar antes, cancele a OS com `POST /api/v1/service-orders/{id}/cancel` (token da equipe): o cancelamento dispara as compensações.
- **Saga já expirada ou compensada:** descartar. O estado final da OS (`cancelled`) já foi comunicado ao cliente.

## 5. Encerramento

- Confirmar que a DLQ voltou a 0 e que o alarme está `OK`.
- Conferir se a OS afetada está no estado esperado (`/details` mostra a saga e a timeline).
- Registrar no incidente: fila, quantidade, causa, se houve redrive ou descarte, e a correção feita. Quando a causa foi um contrato quebrado, abrir tarefa para o teste de contrato pegar o caso.
