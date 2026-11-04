#!/usr/bin/env bash
# Gera os Secrets com valores reais em k8s/<servico>/02-secret.local.yaml (ignorados pelo git).
# RASCUNHO do Claude (2026-11-03), a pedido do Nycolas, para o prazo da entrega.
#
# Le os valores do ../.env (nunca imprime nenhum) e dos endpoints da AWS pelo aws CLI.
# Quem faz o base64 e o proprio kubectl (create secret --dry-run=client -o yaml): o YAML
# gerado tem os valores em base64, como o PDF pede.
#
# Uso (da raiz do togglemaster):
#   bash k8s/gerar-secrets-local.sh            gera auth, flag, targeting, analytics e,
#                                               se o ElastiCache e a SERVICE_API_KEY_CLUSTER
#                                               existirem, o evaluation
set -euo pipefail
cd "$(dirname "$0")/.."

envget() { grep -E "^$1=" .env | head -1 | cut -d= -f2- | tr -d '\r\n'; }

RDS_HOST() {
  aws rds describe-db-instances --db-instance-identifier "$1" \
    --query 'DBInstances[0].Endpoint.Address' --output text
}

gen() { # gen <servico> <namespace> <secret> -- <--from-literal ...>
  local svc="$1" ns="$2" name="$3"; shift 3
  kubectl create secret generic "$name" -n "$ns" "$@" --dry-run=client -o yaml \
    > "k8s/$svc/02-secret.local.yaml"
  echo "ok: k8s/$svc/02-secret.local.yaml ($(grep -c '^  [A-Z_]*:' "k8s/$svc/02-secret.local.yaml") chaves)"
}

SQS_URL="$(envget AWS_SQS_URL)"
MASTER_KEY="$(envget MASTER_KEY)"

AUTH_URL="postgres://postgres:$(envget RDS_AUTH_PASSWORD)@$(RDS_HOST togglemaster-auth-db):5432/auth_db?sslmode=require"
FLAG_URL="postgres://postgres:$(envget RDS_FLAG_PASSWORD)@$(RDS_HOST togglemaster-flag-db):5432/flags_db?sslmode=require"
TARG_URL="postgres://postgres:$(envget RDS_TARGETING_PASSWORD)@$(RDS_HOST togglemaster-targeting-db):5432/targeting_db?sslmode=require"

gen auth auth auth-service-secret \
  --from-literal=DATABASE_URL="$AUTH_URL" --from-literal=MASTER_KEY="$MASTER_KEY"
gen flag flag flag-service-secret --from-literal=DATABASE_URL="$FLAG_URL"
gen targeting targeting targeting-service-secret --from-literal=DATABASE_URL="$TARG_URL"
gen analytics analytics analytics-service-secret --from-literal=AWS_SQS_URL="$SQS_URL"

REDIS_HOST="$(aws elasticache describe-cache-clusters --cache-cluster-id togglemaster-redis-001 \
  --show-cache-node-info --query 'CacheClusters[0].CacheNodes[0].Endpoint.Address' --output text 2>/dev/null || true)"
SAK="$(envget SERVICE_API_KEY_CLUSTER || true)"
if [[ -n "$REDIS_HOST" && "$REDIS_HOST" != "None" && -n "$SAK" ]]; then
  gen evaluation evaluation evaluation-service-secret \
    --from-literal=REDIS_URL="redis://$REDIS_HOST:6379" \
    --from-literal=SERVICE_API_KEY="$SAK" \
    --from-literal=AWS_SQS_URL="$SQS_URL"
else
  echo "pendente: evaluation (ElastiCache='${REDIS_HOST:-?}', SERVICE_API_KEY_CLUSTER no .env: $([[ -n "$SAK" ]] && echo sim || echo nao))"
fi
