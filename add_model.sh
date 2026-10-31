#!/usr/bin/env bash
# Admin API로 모델 alias 를 등록·조회·활성/비활성합니다.
# Admin UI Models → Create Model 과 동일한 POST /admin/models 입니다.
#
# 사용:
#   ./add_model.sh --list
#   ./add_model.sh --list --email admin@example.com --password '…'
#   ./add_model.sh claude-sonnet-4-6 \
#     --preset bedrock \
#     --provider-model-id global.anthropic.claude-sonnet-4-6 \
#     --input-price 0.003 --output-price 0.015 \
#     --email admin@example.com --password '…'
#   ./add_model.sh gpt-6-astra \
#     --preset bedrock-runtime-openai \
#     --provider-model-id us.openai.gpt-6-astra \
#     --endpoint-url https://bedrock-runtime.us-east-2.amazonaws.com \
#     --input-price 0.002 --output-price 0.008 \
#     --email admin@example.com --token-file ~/.gateway-cli/oidc-tokens.json
#   ./add_model.sh claude-sonnet-4-6 --activate --email … --password …
#   ./add_model.sh claude-sonnet-4-6 --deactivate --email … --password …
#
# --preset (provider + api_format 기본값):
#   bedrock                 → BEDROCK + BEDROCK_NATIVE
#   bedrock-runtime-openai  → BEDROCK_RUNTIME_OPENAI + OPENAI_RESPONSES
#   mantle-openai           → BEDROCK_MANTLE_OPENAI + OPENAI_RESPONSES
#   mantle-anthropic        → BEDROCK_MANTLE + ANTHROPIC_MESSAGES
#   openmodel               → OPENMODEL + OPENAI_COMPATIBLE
#
# 인증: ClaudeAdmin 역할 사용자의 Cognito id_token (Admin UI와 동일).
#   1) --password / COGNITO_PASSWORD → USER_PASSWORD_AUTH
#   2) --token-file 또는 ~/.gateway-cli/oidc-tokens.json
#
# 설정: 같은 폴더의 config.json (또는 GATEWAY_CONFIG)
# Bedrock 신모델은 IAM bedrock_allowed_model_arns 도 필요할 수 있습니다 (README 참고).
set -euo pipefail

_ROOT="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=load_config.sh
source "$_ROOT/load_config.sh"

ALIAS=""
PROVIDER=""
PROVIDER_MODEL_ID=""
API_FORMAT=""
ENDPOINT_URL=""
DISPLAY_NAME=""
DESCRIPTION=""
INPUT_PRICE=""
OUTPUT_PRICE=""
CACHE_5M="0"
CACHE_1H="0"
CACHE_READ="0"
ACCOUNT_NAME=""
APPLY_TO_SIBLINGS=0
PRESET=""
EMAIL="${ADMIN_EMAIL:-}"
PASSWORD="${COGNITO_PASSWORD:-}"
TOKEN_FILE=""
LIST_MODELS=0
ACTIVATE=""
# ACTIVATE: "" | "1" | "0"

log()  { printf "\033[1;36m[add_model]\033[0m %s\n" "$*"; }
err()  { printf "\033[1;31m[add_model:err]\033[0m %s\n" "$*" >&2; }
ok()   { printf "\033[1;32m[add_model]\033[0m %s\n" "$*"; }

usage() {
  awk 'NR==1{next} /^[^#]/{exit} {sub(/^# ?/,""); print}' "$0"
  exit "${1:-0}"
}

apply_preset() {
  case "$1" in
    bedrock)
      PROVIDER="${PROVIDER:-BEDROCK}"
      API_FORMAT="${API_FORMAT:-BEDROCK_NATIVE}"
      ;;
    bedrock-runtime-openai|runtime-openai|gpt-runtime)
      PROVIDER="${PROVIDER:-BEDROCK_RUNTIME_OPENAI}"
      API_FORMAT="${API_FORMAT:-OPENAI_RESPONSES}"
      ;;
    mantle-openai|codex)
      PROVIDER="${PROVIDER:-BEDROCK_MANTLE_OPENAI}"
      API_FORMAT="${API_FORMAT:-OPENAI_RESPONSES}"
      ;;
    mantle-anthropic|mantle)
      PROVIDER="${PROVIDER:-BEDROCK_MANTLE}"
      API_FORMAT="${API_FORMAT:-ANTHROPIC_MESSAGES}"
      ;;
    openmodel)
      PROVIDER="${PROVIDER:-OPENMODEL}"
      API_FORMAT="${API_FORMAT:-OPENAI_COMPATIBLE}"
      ;;
    *)
      err "알 수 없는 --preset: $1"
      err "허용: bedrock | bedrock-runtime-openai | mantle-openai | mantle-anthropic | openmodel"
      exit 1
      ;;
  esac
}

while [ $# -gt 0 ]; do
  case "$1" in
    -h|--help) usage 0 ;;
    --list) LIST_MODELS=1; shift ;;
    --activate) ACTIVATE="1"; shift ;;
    --deactivate) ACTIVATE="0"; shift ;;
    --preset)
      [ $# -ge 2 ] || { err "--preset 뒤에 값이 필요합니다"; usage 1; }
      PRESET="$2"; shift 2
      ;;
    --provider)
      [ $# -ge 2 ] || { err "--provider 뒤에 값이 필요합니다"; usage 1; }
      PROVIDER="$2"; shift 2
      ;;
    --provider-model-id|--model-id)
      [ $# -ge 2 ] || { err "--provider-model-id 뒤에 값이 필요합니다"; usage 1; }
      PROVIDER_MODEL_ID="$2"; shift 2
      ;;
    --api-format)
      [ $# -ge 2 ] || { err "--api-format 뒤에 값이 필요합니다"; usage 1; }
      API_FORMAT="$2"; shift 2
      ;;
    --endpoint-url|--endpoint)
      [ $# -ge 2 ] || { err "--endpoint-url 뒤에 값이 필요합니다"; usage 1; }
      ENDPOINT_URL="$2"; shift 2
      ;;
    --display-name)
      [ $# -ge 2 ] || { err "--display-name 뒤에 값이 필요합니다"; usage 1; }
      DISPLAY_NAME="$2"; shift 2
      ;;
    --description|--desc)
      [ $# -ge 2 ] || { err "--description 뒤에 값이 필요합니다"; usage 1; }
      DESCRIPTION="$2"; shift 2
      ;;
    --input-price)
      [ $# -ge 2 ] || { err "--input-price 뒤에 값이 필요합니다"; usage 1; }
      INPUT_PRICE="$2"; shift 2
      ;;
    --output-price)
      [ $# -ge 2 ] || { err "--output-price 뒤에 값이 필요합니다"; usage 1; }
      OUTPUT_PRICE="$2"; shift 2
      ;;
    --cache-5m-price)
      [ $# -ge 2 ] || { err "--cache-5m-price 뒤에 값이 필요합니다"; usage 1; }
      CACHE_5M="$2"; shift 2
      ;;
    --cache-1h-price)
      [ $# -ge 2 ] || { err "--cache-1h-price 뒤에 값이 필요합니다"; usage 1; }
      CACHE_1H="$2"; shift 2
      ;;
    --cache-read-price)
      [ $# -ge 2 ] || { err "--cache-read-price 뒤에 값이 필요합니다"; usage 1; }
      CACHE_READ="$2"; shift 2
      ;;
    --account-name)
      [ $# -ge 2 ] || { err "--account-name 뒤에 값이 필요합니다"; usage 1; }
      ACCOUNT_NAME="$2"; shift 2
      ;;
    --apply-to-siblings) APPLY_TO_SIBLINGS=1; shift ;;
    --email)
      [ $# -ge 2 ] || { err "--email 뒤에 값이 필요합니다"; usage 1; }
      EMAIL="$2"; shift 2
      ;;
    --password)
      [ $# -ge 2 ] || { err "--password 뒤에 값이 필요합니다"; usage 1; }
      PASSWORD="$2"; shift 2
      ;;
    --token-file)
      [ $# -ge 2 ] || { err "--token-file 뒤에 경로가 필요합니다"; usage 1; }
      TOKEN_FILE="$2"; shift 2
      ;;
    -*)
      err "알 수 없는 옵션: $1"; usage 1
      ;;
    *)
      if [ -z "$ALIAS" ]; then ALIAS="$1"; shift
      else err "인자가 너무 많습니다: $1"; usage 1
      fi
      ;;
  esac
done

if [ -n "$PRESET" ]; then
  apply_preset "$PRESET"
fi

for cmd in aws python3 curl; do
  if ! command -v "$cmd" >/dev/null 2>&1; then
    err "$cmd 가 필요합니다"
    exit 1
  fi
done

if [ -z "$EMAIL" ] && [ -z "$TOKEN_FILE" ] && [ ! -f "${GATEWAY_CLI_TOKENS:-}" ]; then
  err "Admin 사용자 --email 이 필요합니다 (또는 --token-file / gateway-cli 토큰)"
  usage 1
fi

if [ -n "$EMAIL" ]; then
  case "$EMAIL" in
    *@*) ;;
    *) err "이메일 형식이 아닙니다: $EMAIL"; exit 1 ;;
  esac
fi

log "config=$GATEWAY_CONFIG"
log "admin_api=$ADMIN_API_URL"
[ -n "$EMAIL" ] && log "admin_email=$EMAIL"

ID_TOKEN=""

obtain_id_token_password() {
  local pw="$1"
  [ -n "$EMAIL" ] || { err "비밀번호 인증에는 --email 이 필요합니다"; return 1; }
  log "USER_PASSWORD_AUTH 로 id_token 요청 ($EMAIL)..."
  local resp
  if ! resp="$(aws cognito-idp initiate-auth \
    --auth-flow USER_PASSWORD_AUTH \
    --client-id "$OIDC_CLIENT_ID" \
    --auth-parameters USERNAME="$EMAIL",PASSWORD="$pw" \
    --output json 2>&1)"; then
    err "initiate-auth 실패"
    printf '%s\n' "$resp" >&2
    return 1
  fi
  if printf '%s' "$resp" | grep -q ChallengeName; then
    err "추가 챌린지가 필요합니다. gateway-cli login 또는 Admin UI 로그인으로 비밀번호를 확정하세요."
    return 1
  fi
  ID_TOKEN="$(printf '%s' "$resp" | python3 -c 'import sys,json; print(json.load(sys.stdin)["AuthenticationResult"]["IdToken"])')"
}

obtain_id_token_file() {
  local f="$1"
  [ -f "$f" ] || return 1
  log "토큰 파일에서 id_token 확인: $f"
  ID_TOKEN="$(EMAIL="${EMAIL:-}" TOKEN_FILE="$f" python3 - <<'PY'
import json, os, sys, time, base64
path = os.environ["TOKEN_FILE"]
email = (os.environ.get("EMAIL") or "").strip()
data = json.load(open(path))
tok = data.get("id_token") or data.get("IdToken")
if not tok:
    sys.exit(2)
payload = tok.split(".")[1]
payload += "=" * ((4 - len(payload) % 4) % 4)
claims = json.loads(base64.urlsafe_b64decode(payload))
if email and claims.get("email") != email:
    print(f"email mismatch: token={claims.get('email')!r} want={email!r}", file=sys.stderr)
    sys.exit(3)
exp = int(claims.get("exp") or 0)
if exp < int(time.time()) + 30:
    print("id_token expired", file=sys.stderr)
    sys.exit(4)
print(tok)
PY
)" || return 1
}

if [ -n "$PASSWORD" ]; then
  obtain_id_token_password "$PASSWORD" || exit 1
elif [ -n "$TOKEN_FILE" ]; then
  obtain_id_token_file "$TOKEN_FILE" || { err "토큰 파일을 쓸 수 없습니다: $TOKEN_FILE"; exit 1; }
elif obtain_id_token_file "$GATEWAY_CLI_TOKENS"; then
  ok "캐시된 gateway-cli id_token 사용"
else
  err "비밀번호·유효한 id_token 이 없습니다."
  err "  ./add_model.sh … --email admin@… --password '…'"
  err "  gateway-cli login 후 ./add_model.sh … --email admin@…"
  exit 1
fi

auth_curl() {
  # usage: auth_curl METHOD URL [curl -d args...]
  local method="$1" url="$2"
  shift 2
  local body
  body="$(mktemp)"
  local code
  code="$(curl -sS -o "$body" -w '%{http_code}' \
    -X "$method" "$url" \
    -H "Authorization: Bearer ${ID_TOKEN}" \
    -H "Content-Type: application/json" \
    "$@")" || true
  HTTP_CODE="$code"
  HTTP_BODY_FILE="$body"
}

if [ "$LIST_MODELS" = "1" ]; then
  URL="${ADMIN_API_URL%/}/admin/models"
  log "GET $URL"
  auth_curl GET "$URL"
  if [ "$HTTP_CODE" != "200" ]; then
    err "목록 조회 실패 HTTP $HTTP_CODE"
    cat "$HTTP_BODY_FILE" >&2 || true
    rm -f "$HTTP_BODY_FILE"
    exit 1
  fi
  python3 - <<'PY' "$HTTP_BODY_FILE"
import json, sys
data = json.load(open(sys.argv[1]))
items = data.get("items") or []
print(f"{'ALIAS':<36} {'STATUS':<10} {'PROVIDER':<24} PROVIDER_MODEL_ID")
print("-" * 110)
for m in sorted(items, key=lambda x: x.get("alias") or ""):
    print(
        f"{(m.get('alias') or ''):<36} "
        f"{(m.get('status') or ''):<10} "
        f"{(m.get('provider') or ''):<24} "
        f"{m.get('provider_model_id') or ''}"
    )
print(f"\n총 {len(items)}개")
PY
  rm -f "$HTTP_BODY_FILE"
  exit 0
fi

if [ -z "$ALIAS" ]; then
  err "alias 가 필요합니다 (또는 --list)"
  usage 1
fi

if [ -n "$ACTIVATE" ]; then
  URL="${ADMIN_API_URL%/}/admin/models/${ALIAS}/status"
  ACTIVE_JSON="true"
  [ "$ACTIVATE" = "1" ] || ACTIVE_JSON="false"
  log "PATCH $URL active=$ACTIVE_JSON"
  auth_curl PATCH "$URL" -d "{\"active\": ${ACTIVE_JSON}}"
  if [ "$HTTP_CODE" != "200" ]; then
    err "상태 변경 실패 HTTP $HTTP_CODE"
    cat "$HTTP_BODY_FILE" >&2 || true
    rm -f "$HTTP_BODY_FILE"
    exit 1
  fi
  ok "alias=$ALIAS status 업데이트 완료"
  python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); print("  status:", d.get("status")); print("  provider:", d.get("provider"))' "$HTTP_BODY_FILE"
  rm -f "$HTTP_BODY_FILE"
  exit 0
fi

# Create
if [ -z "$PROVIDER" ] || [ -z "$API_FORMAT" ] || [ -z "$PROVIDER_MODEL_ID" ]; then
  err "생성 시 --provider, --api-format, --provider-model-id 가 필요합니다 (--preset 으로 provider/api_format 생략 가능)"
  usage 1
fi
if [ -z "$INPUT_PRICE" ] || [ -z "$OUTPUT_PRICE" ]; then
  err "생성 시 --input-price, --output-price 가 필요합니다 (USD / 1K tokens)"
  usage 1
fi
if [ "$PROVIDER" = "BEDROCK_RUNTIME_OPENAI" ] && [ -z "$ENDPOINT_URL" ]; then
  err "BEDROCK_RUNTIME_OPENAI 는 --endpoint-url 이 필요합니다 (예: https://bedrock-runtime.us-east-2.amazonaws.com)"
  exit 1
fi

PAYLOAD="$(
  ALIAS="$ALIAS" \
  PROVIDER="$PROVIDER" \
  PROVIDER_MODEL_ID="$PROVIDER_MODEL_ID" \
  API_FORMAT="$API_FORMAT" \
  ENDPOINT_URL="$ENDPOINT_URL" \
  DISPLAY_NAME="$DISPLAY_NAME" \
  DESCRIPTION="$DESCRIPTION" \
  INPUT_PRICE="$INPUT_PRICE" \
  OUTPUT_PRICE="$OUTPUT_PRICE" \
  CACHE_5M="$CACHE_5M" \
  CACHE_1H="$CACHE_1H" \
  CACHE_READ="$CACHE_READ" \
  ACCOUNT_NAME="$ACCOUNT_NAME" \
  APPLY_TO_SIBLINGS="$APPLY_TO_SIBLINGS" \
  python3 - <<'PY'
import json, os

def num(key, default=None):
    raw = (os.environ.get(key) or "").strip()
    if not raw:
        return default
    return raw  # keep as string for JSON decimal-friendly

body = {
    "alias": os.environ["ALIAS"].strip(),
    "provider": os.environ["PROVIDER"].strip(),
    "provider_model_id": os.environ["PROVIDER_MODEL_ID"].strip(),
    "api_format": os.environ["API_FORMAT"].strip(),
    "input_price_per_1k_tokens": num("INPUT_PRICE"),
    "output_price_per_1k_tokens": num("OUTPUT_PRICE"),
    "cache_creation_5m_price_per_1k_tokens": num("CACHE_5M", "0"),
    "cache_creation_1h_price_per_1k_tokens": num("CACHE_1H", "0"),
    "cache_read_price_per_1k_tokens": num("CACHE_READ", "0"),
    "apply_to_siblings": os.environ.get("APPLY_TO_SIBLINGS") == "1",
}
for env_key, json_key in (
    ("ENDPOINT_URL", "endpoint_url"),
    ("DISPLAY_NAME", "display_name"),
    ("DESCRIPTION", "description"),
    ("ACCOUNT_NAME", "account_name"),
):
    val = (os.environ.get(env_key) or "").strip()
    if val:
        body[json_key] = val
print(json.dumps(body, ensure_ascii=False))
PY
)"

URL="${ADMIN_API_URL%/}/admin/models"
log "POST $URL"
log "alias=$ALIAS provider=$PROVIDER api_format=$API_FORMAT"
auth_curl POST "$URL" -d "$PAYLOAD"

if [ "$HTTP_CODE" != "201" ] && [ "$HTTP_CODE" != "200" ]; then
  err "모델 생성 실패 HTTP $HTTP_CODE"
  cat "$HTTP_BODY_FILE" >&2 || true
  echo >&2
  rm -f "$HTTP_BODY_FILE"
  exit 1
fi

ok "모델 등록 완료 (HTTP $HTTP_CODE)"
python3 - <<'PY' "$HTTP_BODY_FILE"
import json, sys
d = json.load(open(sys.argv[1]))
print(f"  alias:             {d.get('alias')}")
print(f"  status:            {d.get('status')}")
print(f"  provider:          {d.get('provider')}")
print(f"  provider_model_id: {d.get('provider_model_id')}")
print(f"  api_format:        {d.get('api_format')}")
print(f"  display_name:      {d.get('display_name')}")
pricing = d.get("pricing") or d.get("current_pricing") or {}
if isinstance(pricing, dict) and pricing:
    print(f"  input/1k:          {pricing.get('input_price_per_1k_tokens')}")
    print(f"  output/1k:         {pricing.get('output_price_per_1k_tokens')}")
PY
rm -f "$HTTP_BODY_FILE"

echo
echo "  # 확인"
echo "  curl -sS \"${ANTHROPIC_BASE_URL%/}/v1/models\" -H \"Authorization: Bearer \$VIRTUAL_KEY\" | head"
echo "  ./add_model.sh --list --email $EMAIL"
echo
echo "  # 팀 whitelist를 쓰는 경우 Admin UI → Models → Team Model Permission 에도 alias를 추가하세요."
echo "  # Bedrock 신모델이면 Terraform bedrock_allowed_model_arns 도 확인하세요."
