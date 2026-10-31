# Runbook: taxa de erro 5xx de um serviço

**Alerta:** `<serviço>: taxa de erro acima de 5% em 5 min` na policy *Ordem de Serviço (prod)* do New Relic (aviso em 2,5%).
**Severidade:** alta no os-service, que atende a equipe, o cliente e o issuer; média no billing e no execution, porque a saga espera a resposta e o prazo protege a OS.

A condição conta só respostas **5xx** das requisições de negócio, sem `/health` e sem Swagger. O agente também marca `error = true` em 4xx (menos 404), mas 4xx é erro do cliente e fica fora.

## 1. Onde está o erro (até 5 min)

Troque o `appName` (`os-service-postech`, `billing-service-postech`, `execution-service-postech`) e o `container_name` (`os-service`, `billing-service`, `execution-service`).

```sql
-- rota e status
SELECT count(*) FROM Transaction
WHERE appName = 'os-service-postech' AND http.statusCode >= 500
FACET name, http.statusCode SINCE 30 minutes ago

-- erro registrado pelo agente (o stack fica em APM → Errors Inbox)
SELECT count(*) FROM TransactionError
WHERE appName = 'os-service-postech' AND http.statusCode >= 500
FACET error.class, error.message SINCE 30 minutes ago

-- log da requisição, com o correlation_id que o cliente recebeu no header X-Correlation-ID
SELECT timestamp, method, path, status, latency_ms, correlation_id, errors
FROM Log WHERE container_name = 'os-service' AND message = 'request' AND status >= 500
SINCE 30 minutes ago LIMIT 50
```

Com um `correlation_id` na mão, `SELECT * FROM Log WHERE correlation_id = '<id>'` mostra tudo o que aquela requisição registrou.

## 2. Causa e ação

| O que aparece | Causa provável | Ação |
|---|---|---|
| Erro começou junto com um deploy | Regressão na imagem nova | `kubectl -n postech rollout undo deploy/<serviço>` e abrir a correção. `rollout history` mostra a revisão anterior. |
| `circuit_breaker_state_changed` com `to = open` (campo `upstream`) | Dependência fora: `billing` ou `execution` (composição do `/details`) ou `mercadopago` (billing) | Tratar a dependência; o breaker volta sozinho para `half-open` e depois `closed`. Ver `SELECT count(*) FROM Log WHERE message = 'upstream_call_retry' FACET upstream, error`. |
| Erro de banco no `error.message` (`connection refused`, `password authentication failed`, `too many clients`) | RDS indisponível ou credencial trocada (os-service e billing) | `aws rds describe-db-instances --query 'DBInstances[].[DBInstanceIdentifier,DBInstanceStatus]'`; conferir o Secret do serviço e reiniciar com `kubectl -n postech rollout restart deploy/<serviço>`. |
| Erro do DynamoDB (execution) | Tabela `executions` ausente ou credencial da `LabRole` expirada no nó | `aws dynamodb describe-table --table-name executions`; o pod herda a `LabRole` pelo IMDS, então uma sessão nova do lab exige reiniciar os pods. |
| Pods reiniciando ou `OOMKilled` | Falta de memória ou CPU | `kubectl -n postech get pods -l app=<serviço>` e `kubectl -n postech describe pod <pod>`; ver a página *Serviços* do dashboard (CPU, memória, pods prontos). |
| `panic_recovered` (execution) ou 500 sem log de negócio | Bug | Pegar o stack no Errors Inbox e corrigir; se veio de um deploy, rollback. |

## 3. Encerramento

- Confirmar no dashboard (página *Serviços*) que a taxa de 5xx voltou a zero e que o incidente fechou.
- Se o erro afetou a saga, conferir se alguma mensagem foi parar na DLQ ([dlq.md](dlq.md)) e se alguma OS foi compensada por isso ([saga-compensacao.md](saga-compensacao.md)).
- Registrar causa, duração e ação no incidente. Se foi deploy, anotar o teste que faltou.
