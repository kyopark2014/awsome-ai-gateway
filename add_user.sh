#!/usr/bin/env bash
# Cognito에 LLM Gateway 사용자를 추가하고 Claude_* 팀 그룹에 넣습니다.
#
# 사용:
#   ./add_user.sh user@example.com
#   ./add_user.sh user@example.com --team Claude_AWS_Users
#   ./add_user.sh user@example.com --admin
#   ./add_user.sh user@example.com --password 'Temp_Pass-1234!'
#   ./add_user.sh user@example.com --existing          # 이미 있으면 그룹만 추가
#   ./add_user.sh --list-groups
#
# 설정: 같은 폴더의 config.json (다른 서버는 config.json 만 수정)
#   또는 GATEWAY_CONFIG=/path/to/config.json
# 환경변수가 있으면 config 보다 우선합니다.
#
# DB 사용자 행은 이 스크립트가 만들지 않습니다.
# 사용자가 gateway-cli login 하거나 Admin UI Cognito 동기화 후 반영됩니다.
set -euo pipefail

_ROOT="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=load_config.sh
source "$_ROOT/load_config.sh"

EMAIL=""
TEMP_PASSWORD=""
ADD_ADMIN=0
EXISTING_ONLY=0
LIST_GROUPS=0

log()  { printf "\033[1;36m[add_user]\033[0m %s\n" "$*"; }
err()  { printf "\033[1;31m[add_user:err]\033[0m %s\n" "$*" >&2; }
ok()   { printf "\033[1;32m[add_user]\033[0m %s\n" "$*"; }

usage() {
  awk 'NR==1{next} /^[^#]/{exit} {sub(/^# ?/,""); print}' "$0"
  exit "${1:-0}"
}

gen_password() {
  # Cognito 기본 정책: 대/소/숫자/특수, 보통 8자 이상
  local raw
  raw="$(openssl rand -base64 18 | tr -d '/+=' | head -c 16)"
  printf 'Tmp_%s!\n' "$raw"
}

while [ $# -gt 0 ]; do
  case "$1" in
    -h|--help) usage 0 ;;
    --list-groups) LIST_GROUPS=1; shift ;;
    --team)
      [ $# -ge 2 ] || { err "--team 뒤에 그룹명이 필요합니다"; usage 1; }
      TEAM_GROUP="$2"; shift 2
      ;;
    --password)
      [ $# -ge 2 ] || { err "--password 뒤에 값이 필요합니다"; usage 1; }
      TEMP_PASSWORD="$2"; shift 2
      ;;
    --admin) ADD_ADMIN=1; shift ;;
    --existing) EXISTING_ONLY=1; shift ;;
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

if ! command -v aws >/dev/null 2>&1; then
  err "aws CLI 가 필요합니다"
  exit 1
fi

if [ "$LIST_GROUPS" = "1" ]; then
  log "User Pool: $USER_POOL_ID ($REGION)"
  aws cognito-idp list-groups \
    --user-pool-id "$USER_POOL_ID" \
    --query 'Groups[].GroupName' --output table
  exit 0
fi

if [ -z "$EMAIL" ]; then
  err "이메일이 필요합니다"
  usage 1
fi

case "$EMAIL" in
  *@*) ;;
  *) err "이메일 형식이 아닙니다: $EMAIL"; exit 1 ;;
esac

# 팀 그룹은 OIDC_GROUP_PREFIX 접두사 필수 (Admin 그룹 제외)
if [ "$TEAM_GROUP" = "$ADMIN_GROUP" ]; then
  err "TEAM_GROUP 에 $ADMIN_GROUP 을 넣지 마세요. 팀은 --team ${OIDC_GROUP_PREFIX}... 로, Admin 은 --admin 을 쓰세요."
  exit 1
fi
case "$TEAM_GROUP" in
  "${OIDC_GROUP_PREFIX}"*) ;;
  *)
    err "팀 그룹은 ${OIDC_GROUP_PREFIX} 로 시작해야 합니다 (현재: $TEAM_GROUP). 예: ${OIDC_GROUP_PREFIX}AWS_Users"
    err "목록: ./add_user.sh --list-groups"
    exit 1
    ;;
esac

log "config=$GATEWAY_CONFIG"
log "region=$REGION pool=$USER_POOL_ID"
log "email=$EMAIL team=$TEAM_GROUP admin=$ADD_ADMIN existing_only=$EXISTING_ONLY"

# 그룹 존재 확인
if ! aws cognito-idp get-group \
  --user-pool-id "$USER_POOL_ID" \
  --group-name "$TEAM_GROUP" >/dev/null 2>&1; then
  err "팀 그룹이 없습니다: $TEAM_GROUP"
  err "먼저: ./add_team.sh <팀명>   또는 ./add_team.sh --list-groups"
  exit 1
fi

user_exists=0
if aws cognito-idp admin-get-user \
  --user-pool-id "$USER_POOL_ID" \
  --username "$EMAIL" >/dev/null 2>&1; then
  user_exists=1
fi

if [ "$EXISTING_ONLY" = "1" ]; then
  if [ "$user_exists" != "1" ]; then
    err "사용자가 없습니다: $EMAIL (--existing 은 그룹만 추가)"
    exit 1
  fi
  log "기존 사용자 — 그룹만 추가합니다"
elif [ "$user_exists" = "1" ]; then
  err "이미 존재하는 사용자입니다: $EMAIL"
  err "그룹만 추가하려면: ./add_user.sh $EMAIL --existing --team $TEAM_GROUP"
  exit 1
else
  if [ -z "$TEMP_PASSWORD" ]; then
    TEMP_PASSWORD="$(gen_password)"
  fi
  log "Cognito 사용자 생성 중..."
  aws cognito-idp admin-create-user \
    --user-pool-id "$USER_POOL_ID" \
    --username "$EMAIL" \
    --user-attributes \
      Name=email,Value="$EMAIL" \
      Name=email_verified,Value=true \
    --temporary-password "$TEMP_PASSWORD" \
    --message-action SUPPRESS \
    --query 'User.{Username:Username,Status:UserStatus}' --output table
  ok "사용자 생성 완료 (임시 비밀번호는 아래에 출력)"
fi

log "팀 그룹 추가: $TEAM_GROUP"
aws cognito-idp admin-add-user-to-group \
  --user-pool-id "$USER_POOL_ID" \
  --username "$EMAIL" \
  --group-name "$TEAM_GROUP"

if [ "$ADD_ADMIN" = "1" ]; then
  log "Admin 그룹 추가: $ADMIN_GROUP"
  aws cognito-idp admin-add-user-to-group \
    --user-pool-id "$USER_POOL_ID" \
    --username "$EMAIL" \
    --group-name "$ADMIN_GROUP"
fi

STATUS="$(aws cognito-idp admin-get-user \
  --user-pool-id "$USER_POOL_ID" \
  --username "$EMAIL" \
  --query 'UserStatus' --output text)"
ok "UserStatus=$STATUS"

echo
log "소속 그룹:"
aws cognito-idp admin-list-groups-for-user \
  --user-pool-id "$USER_POOL_ID" \
  --username "$EMAIL" \
  --query 'Groups[].GroupName' --output table

echo
ok "사용자에게 전달하세요"
cat <<EOF

  이메일:              $EMAIL
$([ "$EXISTING_ONLY" = "1" ] || printf '  임시 비밀번호:        %s\n  (첫 로그인 시 비밀번호 변경)\n' "$TEMP_PASSWORD")
  팀 그룹:             $TEAM_GROUP
$([ "$ADD_ADMIN" = "1" ] && printf '  Admin 그룹:          %s\n' "$ADMIN_GROUP")

  # gateway-cli 로그인
  export OIDC_ISSUER_URL="$OIDC_ISSUER_URL"
  export OIDC_CLIENT_ID="$OIDC_CLIENT_ID"
  export ADMIN_API_URL="$ADMIN_API_URL"
  export ANTHROPIC_BASE_URL="$ANTHROPIC_BASE_URL"
  gateway-cli login

  DB 반영: 위 로그인(또는 Admin UI → Cognito 동기화) 후
  팀 예산 미설정이면 API 429 — Admin UI Budgets 에서 활성화

EOF
