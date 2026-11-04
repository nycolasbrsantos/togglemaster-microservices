# Manifestos Kubernetes do ToggleMaster (Fase 2)

> **RASCUNHO** redigido pelo Claude em 2026-11-03, a pedido do Nycolas (prazo da entrega).
> Revisar antes de aplicar. Nenhum valor real esta neste diretorio: os Secrets trazem
> placeholders `PREENCHER_...` codificados em base64.

## Siglas

EKS (Kubernetes gerenciado da AWS), ECR (registro de imagens), RDS (Postgres gerenciado),
HPA (Horizontal Pod Autoscaler), LB (Load Balancer), IMDS (servico de metadados da instancia EC2),
TLS (criptografia em transito).

## Estrutura

```
k8s/
  00-namespaces.yaml          5 namespaces: auth, flag, targeting, evaluation, analytics
  <servico>/01-configmap.yaml porta, URLs internas, regiao (nao sensivel)
  <servico>/02-secret.yaml    DATABASE_URL, MASTER_KEY, SERVICE_API_KEY, REDIS_URL, AWS_SQS_URL (base64)
  <servico>/03-deployment.yaml imagem do ECR :1.0.0, requests/limits, readiness e liveness em /health
  <servico>/04-service.yaml   ClusterIP
  db-init/<svc>-db-init.yaml  ConfigMap com o init.sql + Job psql (o RDS e privado, so o cluster alcanca)
  ingress/<svc>-ingress.yaml  um Ingress por namespace (classe nginx), todos no mesmo LB
  hpa/<svc>-hpa.yaml          HPA por CPU 70% no evaluation e no analytics
```

## Decisoes (para defender no video)

- **Um namespace por servico.** O PDF pede separar por namespace; cada servico tem seu Secret
  isolado (o flag nao enxerga a senha do RDS do auth). A chamada entre servicos usa o DNS completo,
  ex.: `http://auth-service.auth.svc.cluster.local:8001`.
- **ConfigMap x Secret.** ConfigMap: porta, URLs internas, regiao, nome da tabela. Secret: tudo que
  veio da etapa 2 e e sensivel (senha do RDS dentro do `DATABASE_URL`, endpoint do ElastiCache,
  URL da fila, `MASTER_KEY`, `SERVICE_API_KEY`).
- **Ingress e rewrite.** O Ingress tem de estar no namespace do Service de destino, entao ha um
  Ingress por namespace; o Nginx junta todos num LB so. As anotacoes valem por objeto.

  | Caminho no LB | Vai para | Rewrite | Motivo |
  |---|---|---|---|
  | `/auth/...` | auth-service | sim, `/auth/validate` vira `/validate` | rotas do codigo nao tem prefixo |
  | `/flags...` | flag-service | nao | rotas ja comecam em `/flags` |
  | `/targeting/...` | targeting-service | sim, `/targeting/rules/x` vira `/rules/x` | rotas comecam em `/rules` |
  | `/evaluate` | evaluation-service | nao | rota ja e `/evaluate` |

  **analytics sem Ingress:** ele so expoe `/health`; e um worker de fila, nao recebe trafego de usuario.
- **Probes.** Todos os servicos tem `/health` que responde 200 sem tocar no banco. Readiness tira o
  pod do Service enquanto nao responde; liveness reinicia o pod travado.
- **Resources.** Go: request 50m/64Mi, limit 250m/128Mi (binarios estaticos de ~20 MB).
  Python/gunicorn: request 100m/128Mi, limit 500m/256Mi. O HPA calcula os 70% sobre o **request**.
  Cabe com folga em 2 nos `t4g.medium` (2 vCPU, 4 GiB cada).
- **auth com 2 replicas.** E dependencia critica (fail-closed: sem auth, flag e targeting devolvem 503).
- **Credenciais AWS pela LabRole.** evaluation (SQS) e analytics (SQS, DynamoDB) usam a role do node
  group via IMDS; os SDKs (aws-sdk-go e boto3) acham essas credenciais sozinhos e elas se renovam.
  Nenhuma chave no Secret. Fallback comentado no `02-secret.yaml` caso o log mostre `NoCredentials`.
- **Arquitetura.** Imagens arm64 e nos Graviton `t4g` (arm64): nao precisa de nodeSelector.
- **db-init como Job.** O RDS esta em sub-rede privada, entao o `init.sql` roda de dentro do cluster
  (imagem `postgres:17-alpine`, mesma versao do RDS 17.11). Reusa o `DATABASE_URL` do Secret.

## Antes de aplicar: preencher os Secrets

**Nao edite o `02-secret.yaml` versionado.** Copie para um arquivo ignorado pelo git:

```bash
cp k8s/auth/02-secret.yaml k8s/auth/02-secret.local.yaml   # idem para os outros 4
```

Gerar cada valor em base64 **sem quebra de linha** (`echo` acrescenta `\n` e quebra a URL):

```bash
printf %s 'valor-real' | base64
```

| Secret (namespace) | Chave | De onde vem |
|---|---|---|
| auth-service-secret (auth) | `DATABASE_URL` | `postgres://<usuario>:<senha>@<endpoint RDS auth>:5432/auth_db` (endpoint na aba Conectividade do RDS) |
| auth-service-secret (auth) | `MASTER_KEY` | gerar: `openssl rand -hex 32` |
| flag-service-secret (flag) | `DATABASE_URL` | idem, RDS do flag, banco `flags_db` |
| targeting-service-secret (targeting) | `DATABASE_URL` | idem, RDS do targeting, banco `targeting_db` |
| evaluation-service-secret (evaluation) | `REDIS_URL` | `redis://<endpoint primario ElastiCache>:6379` (`rediss://` se a criptografia em transito estiver ligada) |
| evaluation-service-secret (evaluation) | `SERVICE_API_KEY` | criada no passo 5 abaixo, **depois** do auth no ar |
| evaluation-service-secret (evaluation) | `AWS_SQS_URL` | URL da fila `togglemaster-events` |
| analytics-service-secret (analytics) | `AWS_SQS_URL` | idem |

Senha com caracteres especiais (`@`, `/`, `:`) quebra a URL: use senha so com letras e numeros no RDS.
O banco inicial (`auth_db`, `flags_db`, `targeting_db`) e definido na criacao do RDS em
"Configuracao adicional > Nome do banco de dados inicial"; sem ele, o banco nao existe.

## Ordem de aplicacao

```bash
# 0. pre-requisitos do cluster (PDF)
kubectl apply -f https://github.com/kubernetes-sigs/metrics-server/releases/latest/download/components.yaml
helm repo add ingress-nginx https://kubernetes.github.io/ingress-nginx
helm install ingress-nginx ingress-nginx/ingress-nginx -n ingress-nginx --create-namespace

# 1. namespaces
kubectl apply -f k8s/00-namespaces.yaml

# 2. config e secrets (os .local.yaml com valores reais)
kubectl apply -f k8s/auth/01-configmap.yaml -f k8s/auth/02-secret.local.yaml
kubectl apply -f k8s/flag/01-configmap.yaml -f k8s/flag/02-secret.local.yaml
kubectl apply -f k8s/targeting/01-configmap.yaml -f k8s/targeting/02-secret.local.yaml

# 3. tabelas nos 3 RDS
kubectl apply -f k8s/db-init/
kubectl get jobs -A                          # COMPLETIONS 1/1 nos tres
kubectl logs -n auth job/auth-service-db-init   # lista a tabela api_keys

# 4. auth, flag, targeting
kubectl apply -f k8s/auth/03-deployment.yaml -f k8s/auth/04-service.yaml
kubectl apply -f k8s/flag/03-deployment.yaml -f k8s/flag/04-service.yaml
kubectl apply -f k8s/targeting/03-deployment.yaml -f k8s/targeting/04-service.yaml
kubectl apply -f k8s/ingress/
kubectl get pods -A

# 5. SERVICE_API_KEY (pelo Ingress)
LB=$(kubectl get svc -n ingress-nginx ingress-nginx-controller -o jsonpath='{.status.loadBalancer.ingress[0].hostname}')
curl -s -X POST "http://$LB/auth/admin/keys" -H "Content-Type: application/json" \
  -H "Authorization: Bearer <MASTER_KEY>" -d '{"name": "evaluation-service"}'
# copie o campo "key" para o SERVICE_API_KEY do evaluation (base64)

# 6. evaluation e analytics
kubectl apply -f k8s/evaluation/ -f k8s/evaluation/02-secret.local.yaml
kubectl apply -f k8s/analytics/ -f k8s/analytics/02-secret.local.yaml
kubectl apply -f k8s/hpa/
```

(No passo 6, `kubectl apply -f k8s/evaluation/` tambem aplica o `02-secret.yaml` de placeholder;
o `.local.yaml` logo em seguida sobrescreve. Para evitar a janela com placeholder, aplique os
arquivos um a um como no passo 4.)

## Verificacao pelo LB do Ingress

```bash
curl -s "http://$LB/auth/health"
curl -s "http://$LB/flags" -H "Authorization: Bearer <SERVICE_API_KEY>"
curl -s -X POST "http://$LB/flags" -H "Content-Type: application/json" -H "Authorization: Bearer <SERVICE_API_KEY>" \
  -d '{"name": "enable-new-checkout", "description": "Novo checkout", "is_enabled": true}'
curl -s -X POST "http://$LB/targeting/rules" -H "Content-Type: application/json" -H "Authorization: Bearer <SERVICE_API_KEY>" \
  -d '{"flag_name": "enable-new-checkout", "is_enabled": true, "rules": {"type": "PERCENTAGE", "value": 50}}'
curl -s "http://$LB/evaluate?user_id=user-123&flag_name=enable-new-checkout"
```

O LB leva alguns minutos para resolver no DNS depois de criado.

## HPA (testes do video)

```bash
kubectl get hpa -A -w     # em outro terminal
hey -z 120s -c 50 "http://$LB/evaluate?user_id=user-123&flag_name=enable-new-checkout"
```

Analytics: os eventos do `/evaluate` enchem a fila; o worker processa mais e a CPU sobe. Ele e
limitado por I/O, entao a CPU pode nao passar de 70% do request de 100m: se nao escalar, isso e
exatamente a justificativa HPA x KEDA do video (KEDA escalaria pela profundidade da fila).

## Pontos em aberto (conferir na hora)

1. **IMDS e hop limit.** Pods so leem a LabRole se o limite de saltos do IMDSv2 do no for 2. Node
   group gerenciado pelo console costuma vir assim; se o analytics logar `NoCredentials`, usar o
   fallback de chaves no Secret.
2. **LabRole com SQS e DynamoDB.** O Readme do lab diz que a LabRole acessa muitos servicos; a
   confirmar pelos logs.
3. **SSL no RDS.** RDS Postgres 17 exige SSL por padrao (`rds.force_ssl`). pgx (auth), psycopg2
   (flag, targeting) e psql usam `sslmode=prefer`, que negocia SSL: deve funcionar sem mudar nada.
   Se der erro de SSL, acrescentar `?sslmode=require` no fim do `DATABASE_URL`.
4. **Criptografia em transito no ElastiCache.** Se ligada, o `REDIS_URL` precisa ser `rediss://`.
5. **Nginx Ingress Controller.** O projeto ingress-nginx anunciou aposentadoria em 2025; o PDF exige
   ele e o chart segue instalavel. A confirmar que o `helm install` funciona na versao atual do chart.
6. **Tabela DynamoDB** `ToggleMasterAnalytics` (chave `event_id`, String) criada pelo console antes do analytics.
