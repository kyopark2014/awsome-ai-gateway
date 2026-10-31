#!/usr/bin/env bash
# Copyright 2026 © Amazon.com and Affiliates: This deliverable is considered Developed Content as defined in the AWS Service Terms.

# ==============================================================================
# sync-chat-reader-secret.sh
# ------------------------------------------------------------------------------
# admin-chat-agent query_db Lambda 가 쓰는
#   /llm-gateway/<env>/chat-agent/reader
# 시크릿에 AWSCURRENT 버전을 보장하고, Aurora 의 gateway_chat_reader 롤
# 비밀번호와 동기화한다.
#
# 배경:
#   Terraform 은 secret *shell* 만 만든다 (비밀번호는 state 에 안 올림).
#   버전(AWSCURRENT)이 없으면 GetSecretValue 가
#     ResourceNotFoundException: ... staging label: AWSCURRENT
#   로 실패하고 BI Insight 의 query_db 가 전부 막힌다.
#
# 사용법:
#   ./sync-chat-reader-secret.sh --env prod
#   ./sync-chat-reader-secret.sh --env prod --rotate   # 기존 AWSCURRENT 있어도 재발급
#   ./sync-chat-reader-secret.sh --env prod --check    # 상태만 확인 (쓰기 없음)
#
# 필요:
#   - aws CLI (Secrets Manager + RDS describe)
#   - kubectl (llm-gateway 네임스페이스 admin-api Running 파드)
#   - jq, python3
# ==============================================================================

set -euo pipefail

ENV=""
ROTATE=0
CHECK_ONLY=0
AWS_REGION="${AWS_REGION:-ap-northeast-2}"
NAMESPACE="${NAMESPACE:-llm-gateway}"
PROJECT="${PROJECT:-llm-gateway}"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --env) ENV="$2"; shift 2 ;;
    --region) AWS_REGION="$2"; shift 2 ;;
    --namespace|-n) NAMESPACE="$2"; shift 2 ;;
    --rotate) ROTATE=1; shift ;;
    --check) CHECK_ONLY=1; shift ;;
    -h|--help)
      sed -n '5,30p' "$0"
      exit 0
      ;;
    *) echo "Unknown flag: $1" >&2; exit 1 ;;
  esac
done

if [[ -z "$ENV" ]]; then
  echo "ERROR: --env dev|prod 가 필요합니다." >&2
  exit 1
fi

SECRET_ID="/${PROJECT}/${ENV}/chat-agent/reader"
CLUSTER_ID="${PROJECT}-${ENV}"

R='\033[0;31m'; G='\033[0;32m'; Y='\033[1;33m'; N='\033[0m'
ok() { echo -e "${G}✓${N} $*"; }
warn() { echo -e "${Y}⚠${N} $*"; }
fail() { echo -e "${R}✗${N} $*" >&2; exit 1; }

echo "━━━ chat-agent reader secret sync (env=${ENV}) ━━━"
echo "secret: ${SECRET_ID}"

if ! aws secretsmanager describe-secret --secret-id "$SECRET_ID" --region "$AWS_REGION" >/dev/null 2>&1; then
  fail "Secret 이 없습니다: ${SECRET_ID} (terraform enable_chat_db_tools / enable_db_tools 먼저)"
fi

STAGES_JSON=$(aws secretsmanager describe-secret \
  --secret-id "$SECRET_ID" --region "$AWS_REGION" \
  --query 'VersionIdsToStages' --output json)
HAS_CURRENT=$(python3 -c 'import json,sys; d=json.load(sys.stdin) or {}; print(any("AWSCURRENT" in (v or []) for v in d.values()))' <<<"$STAGES_JSON")

echo "VersionIdsToStages: $STAGES_JSON"

if [[ "$CHECK_ONLY" -eq 1 ]]; then
  if [[ "$HAS_CURRENT" == "True" ]]; then
    ok "AWSCURRENT 존재"
  else
    fail "AWSCURRENT 없음 — ./sync-chat-reader-secret.sh --env ${ENV} 로 복구"
  fi
  exit 0
fi

NEED_PUT=0
if [[ "$HAS_CURRENT" != "True" ]]; then
  warn "AWSCURRENT 없음 → 새 비밀번호를 넣습니다"
  NEED_PUT=1
elif [[ "$ROTATE" -eq 1 ]]; then
  warn "--rotate: 새 비밀번호로 교체합니다"
  NEED_PUT=1
else
  ok "AWSCURRENT 이미 있음 (재발급은 --rotate)"
fi

READER_PW=""
if [[ "$NEED_PUT" -eq 1 ]]; then
  READER_PW=$(python3 -c 'import secrets,string; a=string.ascii_letters+string.digits; print("".join(secrets.choice(a) for _ in range(32)))')
  aws secretsmanager put-secret-value \
    --secret-id "$SECRET_ID" \
    --region "$AWS_REGION" \
    --secret-string "{\"password\":\"${READER_PW}\"}" \
    --query '{VersionId:VersionId,VersionStages:VersionStages}' --output json
  ok "Secrets Manager 에 AWSCURRENT 버전 기록"
else
  READER_PW=$(aws secretsmanager get-secret-value \
    --secret-id "$SECRET_ID" --region "$AWS_REGION" \
    --query 'SecretString' --output text | python3 -c 'import sys,json; print(json.load(sys.stdin)["password"])')
fi

# Master 로 ALTER ROLE (gateway 유저는 CREATEROLE 없음)
MASTER_ARN=$(aws rds describe-db-clusters \
  --db-cluster-identifier "$CLUSTER_ID" --region "$AWS_REGION" \
  --query 'DBClusters[0].MasterUserSecret.SecretArn' --output text)
[[ -n "$MASTER_ARN" && "$MASTER_ARN" != "None" ]] || fail "Aurora master secret ARN 을 찾지 못했습니다 ($CLUSTER_ID)"

MASTER_JSON=$(aws secretsmanager get-secret-value \
  --secret-id "$MASTER_ARN" --region "$AWS_REGION" \
  --query 'SecretString' --output text)
MASTER_USER=$(python3 -c 'import sys,json; print(json.load(sys.stdin)["username"])' <<<"$MASTER_JSON")
MASTER_PW=$(python3 -c 'import sys,json; print(json.load(sys.stdin)["password"])' <<<"$MASTER_JSON")

CLUSTER_HOST=$(aws rds describe-db-clusters \
  --db-cluster-identifier "$CLUSTER_ID" --region "$AWS_REGION" \
  --query 'DBClusters[0].Endpoint' --output text)

POD=$(kubectl get pods -n "$NAMESPACE" --no-headers 2>/dev/null \
  | awk '/admin-api/ && /1\/1/ && /Running/ {print $1; exit}')
[[ -n "$POD" ]] || fail "Running admin-api 파드를 찾지 못했습니다 (ns=${NAMESPACE})"

TMP_PY=$(mktemp)
trap 'rm -f "$TMP_PY"; unset MASTER_PW MASTER_JSON READER_PW' EXIT

cat > "$TMP_PY" << 'PY'
import asyncio, os, asyncpg

master_user = os.environ["MASTER_USER"]
master_pw = os.environ["MASTER_PW"]
new_pw = os.environ["NEW_READER_PW"]
host = os.environ["CLUSTER_HOST"]
escaped = new_pw.replace("'", "''")

async def main():
    print(f"connect master@{host}")
    conn = await asyncpg.connect(
        user=master_user, password=master_pw, host=host, port=5432,
        database="gateway", ssl="require", timeout=15,
    )
    try:
        exists = await conn.fetchval(
            "SELECT 1 FROM pg_roles WHERE rolname = $1", "gateway_chat_reader"
        )
        print("role exists:", bool(exists))
        if not exists:
            await conn.execute(
                f"CREATE ROLE gateway_chat_reader LOGIN PASSWORD '{escaped}' NOINHERIT"
            )
            print("CREATED gateway_chat_reader (GRANT 는 db/init/08_create_chat_reader.sql 재실행 필요)")
        else:
            await conn.execute(
                f"ALTER ROLE gateway_chat_reader WITH PASSWORD '{escaped}'"
            )
            print("ALTER ROLE gateway_chat_reader password updated")
    finally:
        await conn.close()

    rconn = await asyncpg.connect(
        user="gateway_chat_reader", password=new_pw, host=host, port=5432,
        database="gateway", ssl="require", timeout=15,
    )
    try:
        v = await rconn.fetchval("SELECT current_user")
        print("reader login ok:", v)
    finally:
        await rconn.close()

asyncio.run(main())
PY

kubectl cp "$TMP_PY" "${NAMESPACE}/${POD}:/tmp/sync_chat_reader_secret.py"
kubectl exec -n "$NAMESPACE" "$POD" -- \
  env MASTER_USER="$MASTER_USER" MASTER_PW="$MASTER_PW" \
      NEW_READER_PW="$READER_PW" CLUSTER_HOST="$CLUSTER_HOST" \
  python3 /tmp/sync_chat_reader_secret.py
kubectl exec -n "$NAMESPACE" "$POD" -- rm -f /tmp/sync_chat_reader_secret.py >/dev/null 2>&1 || true

ok "gateway_chat_reader 비밀번호 동기화 완료"
echo ""
echo "검증 예:"
echo "  aws lambda invoke --function-name ${PROJECT}-${ENV}-chat-agent-query-db \\"
echo "    --cli-binary-format raw-in-base64-out \\"
echo "    --payload '{\"sql\":\"SELECT 1 AS ok\",\"session_id\":\"sync-check\",\"step_id\":\"1\"}' \\"
echo "    /tmp/q.json && python3 -m json.tool /tmp/q.json"
