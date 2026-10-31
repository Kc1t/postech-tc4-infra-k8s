# Runbook: latência p95 alta num serviço

**Alerta:** `<serviço>: latência p95 acima de <N> s em 5 min` (1 s no os-service e no execution, 2 s no billing, que chama o Mercado Pago). O aviso abre na metade do limite.
**Severidade:** média. O SLO do os-service é 95% das requisições abaixo de 500 ms; latência alta queima esse orçamento antes de virar erro.

## 1. O que está lento (até 5 min)

```sql
-- rotas mais lentas
SELECT percentile(duration, 95) * 1000 AS 'p95 ms', count(*) FROM Transaction
WHERE appName = 'os-service-postech' AND transactionType = 'Web' AND name NOT LIKE '%/health%'
FACET name SINCE 30 minutes ago

-- tempo gasto em chamadas externas e no DynamoDB, por destino
SELECT percentile(duration.ms, 95), count(*) FROM Span
WHERE appName = 'os-service-postech' AND span.kind = 'client'
FACET name SINCE 30 minutes ago
```

- `External/billing-service/...` ou `External/execution-service/...` no os-service: a composição do `/details` espera os outros serviços (timeout `UPSTREAM_TIMEOUT` de 2 s).
- `External/api.mercadopago.com/...` no billing: o provedor está lento (timeout `MP_TIMEOUT` de 5 s).
- `Datastore/.../DynamoDB/...` no execution: consultas à tabela `executions` (instrumentadas pelo `nrawssdk-v2`).
- Se nenhum span de cliente explica o tempo, ele está no Postgres: o agente não instrumenta o GORM, então o banco aparece como tempo da própria transação. Confirme no RDS (*Performance Insights* ou `pg_stat_activity`).

Um trace de exemplo: APM → serviço → *Distributed tracing*, filtro `duration > 1`.

## 2. Causa e ação

| O que aparece | Causa provável | Ação |
|---|---|---|
| CPU perto do limite e HPA no máximo (6 réplicas) | Carga acima da capacidade | `kubectl -n postech get hpa`; `kubectl top pods -n postech`. A `ResourceQuota` do namespace limita o total: aumentar a quota ou o `maxReplicas` em `k8s/hpa.yaml` do serviço. |
| Pods prontos abaixo do desejado | Pods reiniciando ou sem nó | `kubectl -n postech get pods -o wide`; com nós cheios, `aws eks update-nodegroup-config` (até 5 nós). |
| Só o billing, em `External/api.mercadopago.com` | Lentidão do Mercado Pago | Nada a fazer no código; se persistir, o `circuit_breaker_state_changed` abre e o pagamento falha rápido. Avisar no incidente. |
| Só o os-service, no `/details` | billing ou execution lentos | Seguir este runbook no serviço lento. |
| Lentidão começou com um deploy | Regressão (consulta nova, N+1) | `kubectl -n postech rollout undo deploy/<serviço>`. |

## 3. Encerramento

- p95 abaixo do limite por 10 min e incidente fechado.
- Ver quanto do orçamento do SLO de latência do os-service foi consumido (*Service levels*) e registrar no incidente.
