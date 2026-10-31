# Runbook: erro nas Lambdas

**Alertas:**
- `lambda <issuer|authorizer|notifier>: taxa de erro acima de 5% em 5 min`: invocações com `error = true` (NoticeError ou erro devolvido ao runtime).
- `lambda notifier: falhas de envio de e-mail acima de 4 em 5 min`: logs `notification_send_failed`, `notification_dedup_failed` e `notification_render_failed`. A Lambda de notificação devolve a mensagem que falhou para a fila (`ReportBatchItemFailures`) sem marcar erro na invocação, então o sinal dela é o log.

**Severidade:** alta no authorizer (todas as rotas protegidas param) e no issuer (o cliente não consegue token); média no notifier (a OS segue, o e-mail atrasa ou se perde na DLQ).

| Function | Nome na AWS | Log group |
|---|---|---|
| issuer | `postech-tc4-prod-auth-issuer` | `/aws/lambda/postech-tc4-prod-auth-issuer` |
| authorizer | `postech-tc4-prod-auth-authorizer` | `/aws/lambda/postech-tc4-prod-auth-authorizer` |
| notifier | `postech-tc4-prod-notifier` | `/aws/lambda/postech-tc4-prod-notifier` |

## 1. Qual erro (até 5 min)

```sql
SELECT timestamp, aws.lambda.arn, error.class, error.message, aws.requestId
FROM TransactionError WHERE aws.lambda.arn LIKE '%:function:postech-tc4-prod-%' SINCE 1 hour ago LIMIT 50
```

```bash
aws logs tail /aws/lambda/postech-tc4-prod-auth-issuer --since 30m --format short
```

O CloudWatch mostra também o que não chega ao New Relic: falha no init (variável obrigatória ausente encerra o processo antes do agente subir), timeout e falta de memória (`Task timed out`, `Runtime exited`).

## 2. Causa e ação

**issuer** (`POST /auth`, CPF → JWT). Só marca erro nos caminhos 5xx; CPF inválido, cliente inexistente ou inativo são 4xx e ficam em `auth.outcome`.

| Log / erro | Causa | Ação |
|---|---|---|
| `os-service indisponivel` (503) | O os-service não respondeu ou deu 5xx em `GET /internal/requesters/{documento}` | Ver [servico-erros.md](servico-erros.md) no os-service. Conferir se o NLB `os-service-public` existe: o issuer acha a URL por ele no deploy. |
| `falha ao consultar cliente` com `os-service respondeu 401` | `INTERNAL_API_TOKEN` diferente entre o os-service e a Lambda | `scripts/setup-github.sh app` grava o mesmo valor nos dois; refazer o deploy dos dois repositórios. |
| `falha ao assinar token` | `JWT_SECRET` vazio ou inválido | Conferir o secret no `postech-tc4-lambda-auth` e refazer o deploy. |

**authorizer** (valida o JWT de toda rota protegida). Negar token não é erro (é `auth.outcome`, ver [authorizer-negacoes.md](authorizer-negacoes.md)); erro aqui é a function quebrada.

| Sinal | Causa | Ação |
|---|---|---|
| `variavel obrigatoria ausente` no CloudWatch, gateway devolvendo 500 | `JWT_SECRET` não chegou à function | Refazer o deploy do `postech-tc4-lambda-auth` com o secret configurado. |
| `Task timed out` | Timeout de 5 s (cold start com a layer do New Relic) | Ver `aws.lambda.coldStart` na página *Lambdas*; se for recorrente, subir `memory_size` em `infra/main.tf`. |

**notifier** (fila `notification-os-events` → e-mail).

```sql
SELECT timestamp, message, error, to, service_order_code, status FROM Log
WHERE message LIKE 'notification_%' AND message NOT IN ('notification_sent', 'notification_ignored', 'notification_duplicate')
SINCE 1 hour ago LIMIT 50
```

| Log | Causa | Ação |
|---|---|---|
| `notification_send_failed` | SMTP do Brevo recusou: credencial (`SMTP_USERNAME`, `SMTP_PASSWORD`), remetente não verificado (`SMTP_FROM`) ou cota diária | `scripts/setup-github.sh smtp` e refazer o deploy; a cota se confere no painel do Brevo. A mensagem volta para a fila e é tentada de novo. |
| `notification_dedup_failed` | Tabela `postech-tc4-prod-notifier-dedup` inacessível | `aws dynamodb describe-table --table-name postech-tc4-prod-notifier-dedup`; a function usa a `LabRole`. |
| `notification_render_failed` | Template quebrado para o status | Corrigir `internal/templates` e publicar. |

Depois de 5 entregas sem sucesso a mensagem vai para `notification-os-events-dlq`: corrigir e fazer o redrive ([dlq.md](dlq.md)). O dedup por `message_id` impede e-mail repetido.

## 3. Encerramento

- Taxa de erro de volta a zero na página *Lambdas* e `NotificationSent` voltando a crescer, no caso do notifier.
- Registrar a causa e, se o deploy mudou variável ou secret, qual.
