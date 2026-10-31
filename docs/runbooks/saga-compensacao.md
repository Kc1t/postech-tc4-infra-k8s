# Runbook: taxa de compensação da saga alta

**Alerta:** `saga: taxa de compensação acima de 30% em 30 min` (aviso em 15%).
**Severidade:** média. Compensar é o comportamento correto quando uma etapa falha: o alerta não diz que algo quebrou, diz que muitas OS estão terminando canceladas e é preciso separar decisão de negócio de falha técnica.

A taxa é `saga_compensated / (saga_completed + saga_compensated)` nos logs do orquestrador (os-service). Uma saga expirada também loga `saga_compensated`.

## 1. Por que as sagas estão compensando (até 10 min)

```sql
SELECT count(*) FROM Log WHERE message = 'saga_compensated' FACET reason SINCE 1 hour ago

SELECT timestamp, service_order_code, saga_id, previous_status, reason, refund_payment
FROM Log WHERE message = 'saga_compensated' SINCE 1 hour ago LIMIT 50
```

O widget *Motivos de compensação* (página *Saga*) agrupa os mesmos motivos. O SLO *saga: OS encerradas sem compensação técnica* conta como ruins só as linhas marcadas como técnicas abaixo.

| Motivo (`reason`) | Tipo | O que fazer |
|---|---|---|
| contém `simulate_failure=` | falha simulada | Esperado na demo (`X-Simulate-Failure` com `FAULT_INJECTION_ENABLED=true`). Fora da demo, desligar com `scripts/setup-github.sh vars` e refazer o deploy dos serviços. |
| `orçamento recusado pelo cliente`, `cancelada pela oficina` | negócio | Nenhuma ação técnica. |
| `prazo de aprovação ... expirado`, `prazo de pagamento expirado` | negócio | Ver [saga-expirada.md](saga-expirada.md): muitas de uma vez podem ser resposta perdida. |
| `estoque insuficiente para a peça X` | negócio | Repor o estoque da peça no catálogo do os-service. |
| `pagamento não aprovado: pagamento rejected pelo provedor (...)` ou `cancelled` | negócio | O Mercado Pago recusou ou cancelou o pagamento; o `status_detail` vem entre parênteses. |
| outro `pagamento não aprovado: ...` | **técnica** | Billing: `SELECT timestamp, reason, budget_id FROM Log WHERE message = 'payment_failed'`. `provedor recusou a criação do checkout` = `MP_ACCESS_TOKEN` inválido ou expirado; `orçamento não encontrado` = o billing não tem o orçamento que a saga citou (dados divergentes entre os serviços). |
| `falha ao gerar o orçamento: ...` | **técnica** | Billing: `SELECT timestamp, reason FROM Log WHERE message = 'budget_creation_failed'`. |
| `serviço N não existe no catálogo`, `peça X não existe no catálogo`, `quantidade inválida`, `diagnóstico sem serviços nem peças` | **técnica** (dados) | O diagnóstico do execution citou item que o catálogo do os-service não tem: cadastrar o item ou corrigir o diagnóstico. |
| `execução recusada pela oficina: capacidade de reparos esgotada` | negócio | A oficina está no limite (`MAX_CONCURRENT_REPAIRS`, 10 no ConfigMap do execution). Concluir reparos ou aumentar o limite. |
| outro `execução recusada pela oficina: ...` | **técnica** | `execução não encontrada` ou `execução em <status> não pode iniciar reparo`: o estado no DynamoDB não bate com a saga. Ver a execução em `GET /api/v1/executions/...` e o log `repair_rejected`. |

## 2. As compensações terminaram?

Compensar dispara comandos (`RefundPayment`, `CancelBudget`, `CancelExecution`) e devolve as peças. Confira as confirmações:

```sql
SELECT count(*) FROM Log
WHERE message IN ('saga_compensation_confirmed', 'saga_refund_confirmed', 'payment_refunded', 'budget_cancelled', 'refund_failed')
FACET message SINCE 1 hour ago
```

- `refund_failed` no billing: o estorno não saiu e a saga fica em `compensating`. Corrigir a causa (credencial do Mercado Pago) e reenviar a mensagem pela DLQ ([dlq.md](dlq.md)).
- Saga parada em `compensating`: `SELECT latest(saga_state) FROM Log WHERE message = 'saga_step' AND saga_id = '<saga_id>'`.

## 3. Encerramento

- Taxa de volta abaixo do limite; os motivos técnicos tratados.
- Registrar no incidente quantas OS foram compensadas por motivo técnico (são as que o cliente perdeu por falha nossa).
