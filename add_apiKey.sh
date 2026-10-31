#!/usr/bin/env bash
# Cognito 사용자용 Virtual Key(API Key, vk-…)를 발급합니다.
# Admin UI에 “키 발급”은 없고, OIDC id_token → POST /v1/auth/exchange 로 받습니다.
#
# 사용:
#   ./add_apiKey.sh user@example.com
#   ./add_apiKey.sh user@example.com --password 'YourPassword12'
#   ./add_apiKey.sh user@example.com --set-password 'Temp_Pass-1234!'   # Admin이 영구 비번 설정 후 발급
#   ./add_apiKey.sh user@example.com --token-file ~/.gateway-cli/oidc-tokens.json
#   ./add_apiKey.sh user@example.com --out /tmp/vk.txt
#
# 토큰 확보 순서:
#   1) --password / COGNITO_PASSWORD → USER_PASSWORD_AUTH
#   2) --token-file 또는 ~/.gateway-cli/oidc-tokens.json (email 일치 + 미만료 id_token)
#   3) 없으면 안내 후 종료 (gateway-cli login 유도)
#
# 설정: 같은 폴더의 config.json (다른 서버는 config.json 만 수정)
#   또는 GATEWAY_CONFIG=/path/to/config.json
# 환경변수 / COGNITO_PASSWORD 가 있으면 config 보다 우선합니다.
set -euo pipefail

_ROOT="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=load_config.sh
source "$_ROOT/load_config.sh"

EMAIL=""
PASSWORD="${COGNITO_PASSWORD:-}"
SET_PASSWORD=""
TOKEN_FILE=""
OUT_FILE=""

log()  { printf "\033[1;36m[add_apiKey]\033[0m %s\n" "$*"; }
err()  { printf "\033[1;31m[add_apiKey:err]\033[0m %s\n" "$*" >&2; }
ok()   { printf "\033[1;32m[add_apiKey]\033[0m %s\n" "$*"; }

usage() {
  awk 'NR==1{next} /^[^#]/{exit} {sub(/^# ?/,""); print}' "$0"
  exit "${1:-0}"
}

while [ $# -gt 0 ]; do
  case "$1" in
    -h|--help) usage 0 ;;
    --password)
      [ $# -ge 2 ] || { err "--password 뒤에 값이 필요합니다"; usage 1; }
      PASSWORD="$2"; shift 2
      ;;
    --set-password)
      [ $# -ge 2 ] || { err "--set-password 뒤에 값이 필요합니다"; usage 1; }
      SET_PASSWORD="$2"; shift 2
      ;;
    --token-file)
      [ $# -ge 2 ] || { err "--token-file 뒤에 경로가 필요합니다"; usage 1; }
      TOKEN_FILE="$2"; shift 2
      ;;
    --out)
      [ $# -ge 2 ] || { err "--out 뒤에 경로가 필요합니다"; usage 1; }
      OUT_FILE="$2"; shift 2
      ;;
    -*)
      err "알 수 없는 옵션: $1"; usage 1
      ;;
    *)
      if [ -z "$EMAIL" ]; then EMAIL="$1"; shift
      else err "인자가 너무 많습니다: $1"; usage 1
      fi
      ;;
  esac
done

if [ -z "$EMAIL" ]; then
  err "이메일이 필요합니다"
  usage 1
fi
case "$EMAIL" in
  *@*) ;;
  *) err "이메일 형식이 아닙니다: $EMAIL"; exit 1 ;;
esac

for cmd in aws python3 curl; do
  if ! command -v "$cmd" >/dev/null 2>&1; then
    err "$cmd 가 필요합니다"
    exit 1
  fi
done

log "config=$GATEWAY_CONFIG"
log "region=$REGION pool=$USER_POOL_ID"
log "email=$EMAIL admin_api=$ADMIN_API_URL"

if ! aws cognito-idp admin-get-user \
  --user-pool-id "$USER_POOL_ID" \
  --username "$EMAIL" >/dev/null 2>&1; then
  err "Cognito에 사용자가 없습니다: $EMAIL"
  err "먼저: ./add_user.sh $EMAIL --team $TEAM_GROUP"
  exit 1
fi

STATUS="$(aws cognito-idp admin-get-user \
  --user-pool-id "$USER_POOL_ID" \
  --username "$EMAIL" \
  --query 'UserStatus' --output text)"
# GROUPS 는 zsh 등에서 GID 특수 변수라 쓰지 않습니다.
COGNITO_GROUPS="$(aws cognito-idp admin-list-groups-for-user \
  --user-pool-id "$USER_POOL_ID" \
  --username "$EMAIL" \
  --query 'Groups[].GroupName' --output text | tr '\t' ' ')"
if [ -z "$COGNITO_GROUPS" ]; then
  COGNITO_GROUPS="(none)"
fi
log "UserStatus=$STATUS cognito_groups=$COGNITO_GROUPS"

if ! printf '%s\n' "$COGNITO_GROUPS" | grep -qE "(^|[[:space:]])${OIDC_GROUP_PREFIX}"; then
  err "${OIDC_GROUP_PREFIX}* 팀 그룹이 없습니다. VK 발급이 403 no_matching_team_group 됩니다."
  err "예: ./add_user.sh $EMAIL --existing --team $TEAM_GROUP"
  exit 1
fi

if [ -n "$SET_PASSWORD" ]; then
  log "Admin이 영구 비밀번호를 설정합니다 (--set-password)"
  aws cognito-idp admin-set-user-password \
    --user-pool-id "$USER_POOL_ID" \
    --username "$EMAIL" \
    --password "$SET_PASSWORD" \
    --permanent
  PASSWORD="$SET_PASSWORD"
  STATUS="$(aws cognito-idp admin-get-user \
    --user-pool-id "$USER_POOL_ID" \
    --username "$EMAIL" \
    --query 'UserStatus' --output text)"
  ok "비밀번호 설정 완료 UserStatus=$STATUS"
fi

ID_TOKEN=""

obtain_id_token_password() {
  local pw="$1"
  log "USER_PASSWORD_AUTH 로 id_token 요청..."
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
    err "추가 챌린지가 필요합니다 (신규 임시비번 등). gateway-cli login 으로 비밀번호를 확정하세요."
    printf '%s\n' "$resp" | python3 -c 'import sys,json; d=json.load(sys.stdin); print("ChallengeName=", d.get("ChallengeName"))' 2>/dev/null || true
    return 1
  fi
  ID_TOKEN="$(printf '%s' "$resp" | python3 -c 'import sys,json; print(json.load(sys.stdin)["AuthenticationResult"]["IdToken"])')"
}

obtain_id_token_file() {
  local f="$1"
  [ -f "$f" ] || return 1
  log "토큰 파일에서 id_token 확인: $f"
  ID_TOKEN="$(EMAIL="$EMAIL" TOKEN_FILE="$f" python3 - <<'PY'
import json, os, sys, time, base64
path = os.environ["TOKEN_FILE"]
email = os.environ["EMAIL"]
data = json.load(open(path))
tok = data.get("id_token") or data.get("IdToken")
if not tok:
    sys.exit(2)
payload = tok.split(".")[1]
payload += "=" * ((4 - len(payload) % 4) % 4)
claims = json.loads(base64.urlsafe_b64decode(payload))
if claims.get("email") != email:
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
  err "다음 중 하나를 사용하세요:"
  err "  ./add_apiKey.sh $EMAIL --password '…'"
  err "  ./add_apiKey.sh $EMAIL --set-password '…'   # Admin이 비번 설정 후 발급"
  err "  gateway-cli login 후 다시 ./add_apiKey.sh $EMAIL"
  exit 1
fi

EXCHANGE_URL="${ADMIN_API_URL%/}/v1/auth/exchange"
log "POST $EXCHANGE_URL"

HTTP_BODY="$(mktemp)"
HTTP_CODE="$(curl -sS -o "$HTTP_BODY" -w '%{http_code}' \
  -X POST "$EXCHANGE_URL" \
  -H "Authorization: Bearer ${ID_TOKEN}" \
  -H "Content-Type: application/json" \
  -d '{}')" || true

if [ "$HTTP_CODE" != "200" ]; then
  err "exchange 실패 HTTP $HTTP_CODE"
  cat "$HTTP_BODY" >&2 || true
  echo >&2
  rm -f "$HTTP_BODY"
  exit 1
fi

VK="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("virtual_key") or "")' "$HTTP_BODY")"
rm -f "$HTTP_BODY"

if [ -z "$VK" ]; then
  err "응답에 virtual_key 가 없습니다"
  exit 1
fi

ok "Virtual Key 발급 완료 (1인 1키 — 이전 ACTIVE 키는 만료될 수 있음)"
echo
echo "  email:        $EMAIL"
echo "  virtual_key:  $VK"
echo
echo "  # 사용 예"
echo "  export ANTHROPIC_BASE_URL=\"$ANTHROPIC_BASE_URL\""
echo "  export VIRTUAL_KEY='$VK'"
echo "  curl -sS \"\$ANTHROPIC_BASE_URL/v1/messages\" \\"
echo "    -H \"Authorization: Bearer \$VIRTUAL_KEY\" \\"
echo "    -H \"Content-Type: application/json\" \\"
echo "    -H \"anthropic-version: 2023-06-01\" \\"
echo "    -d '{\"model\":\"<허용모델>\",\"max_tokens\":16,\"messages\":[{\"role\":\"user\",\"content\":\"ping\"}]}'"
echo

if [ -n "$OUT_FILE" ]; then
  umask 077
  printf '%s\n' "$VK" >"$OUT_FILE"
  ok "키를 저장했습니다: $OUT_FILE (mode 0600 권장)"
fi
