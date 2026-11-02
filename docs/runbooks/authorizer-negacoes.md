# Runbook: authorizer negando muitas requisições

**Alerta:** `lambda authorizer: mais de 50 requisições negadas em 5 min` (aviso acima de 25).
**Severidade:** alta se for a própria equipe ou os clientes sendo barrados (todas as rotas protegidas devolvem 403); média se for varredura de fora.

O authorizer (`postech-tc4-prod-auth-authorizer`) roda em toda rota protegida do API Gateway, sem cache, e grava o resultado em `auth.outcome` na transação:

- `missing_token`: header `Authorization` presente, mas fora do formato `Bearer <token>`;
- `invalid_token`: assinatura inválida, token expirado ou claims faltando;
- `allowed`: aceito (com `auth.role`).

Requisição **sem** o header `Authorization` nem invoca o authorizer: o API Gateway responde 401 direto, porque o identity source é `$request.header.Authorization`. Ela não entra neste alerta e só aparece no access log do gateway. Token negado pelo authorizer vira 403.

## 1. Quem está sendo negado (até 5 min)

```sql
SELECT count(*) FROM Transaction
WHERE aws.lambda.arn LIKE '%:function:postech-tc4-prod-auth-authorizer%'
FACET auth.outcome SINCE 1 hour ago TIMESERIES

-- motivo e rota do token rejeitado
SELECT count(*) FROM Log WHERE message = 'token rejeitado' FACET error, route SINCE 1 hour ago
```

IP de origem, pelo access log do gateway no CloudWatch Logs Insights (log group `/aws/apigateway/postech-tc4-prod`):

```
fields ip, routeKey, status, authorizer
| filter status = "401" or status = "403"
| stats count(*) as negadas by ip, routeKey, status
| sort negadas desc
```

`401` é requisição sem header (o authorizer não rodou); `403` é token negado pelo authorizer.

## 2. Causa e ação

| O que aparece | Causa | Ação |
|---|---|---|
| `invalid_token` com erro de assinatura, para todo mundo, logo depois de um deploy | `JWT_SECRET` diferente entre o os-service (emite o token da equipe), o issuer e o authorizer | O segredo precisa ser o mesmo nos quatro repositórios que o usam: `scripts/setup-github.sh app` (só gera de novo com `ROTATE=true`) e refazer o deploy de todos. Depois de uma rotação proposital, os tokens antigos deixam de valer: é esperado. |
| `invalid_token` por expiração, em poucos usuários | Token de 15 min (`JWT_TTL` do issuer, `ACCESS_TOKEN_EXP_MIN` do os-service) sem renovação no cliente | Problema do cliente: renovar pelo `/api/v1/auth/refresh` (equipe) ou pedir token novo em `POST /auth` (cliente). |
| `missing_token` concentrado em uma rota | Cliente ou front mandando o header fora do formato (sem `Bearer`, token vazio) | Corrigir o cliente. |
| Muitos `401` no access log de uma rota | Cliente chamando rota protegida sem header | Corrigir o cliente; conferir se a rota deveria ser aberta (`api_gateway.tf`). |
| Muitos IPs ou um IP só, rotas variadas | Varredura | O gateway já limita a 100 req/s (burst 200). Para conter um IP, baixar o throttling da rota em `api_gateway.tf`; o HTTP API não aceita WAF. |

## 3. Encerramento

- `auth.outcome = 'allowed'` voltando a dominar e incidente fechado.
- Se foi segredo divergente, registrar quais repositórios estavam com o valor antigo.
