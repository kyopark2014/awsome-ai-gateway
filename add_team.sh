#!/usr/bin/env bash
# Cognito에 LLM Gateway 팀 그룹(Claude_*)을 추가합니다.
# Admin UI에서 팀을 만들지 않습니다 — Cognito 그룹이 원천입니다.
#
# 사용:
#   ./add_team.sh Backend
#   ./add_team.sh AWS-Users
#   ./add_team.sh Claude_Backend              # 접두사 포함 전체 이름
#   ./add_team.sh Backend --dept AI-Center    # → Claude_AI-Center_Backend
#   ./add_team.sh Backend --description "…"
#   ./add_team.sh Backend --add-user user@example.com
#   ./add_team.sh --list-groups
#
# 명명 (config oidc_group_prefix, 기본 Claude_):
#   PREFIX + <team>              → Default Department / 팀 <team>
#   PREFIX + <dept> + _ + <team> → 부서 <dept> / 팀 <team>
#   팀·부서 이름에 underscore(_) 금지 — 하이픈(-) 사용 (예: AWS-Users)
#
# 설정: 같은 폴더의 config.json (또는 GATEWAY_CONFIG)
# DB 팀 행은 Cognito 동기화 또는 사용자 gateway-cli login 후 생깁니다.
# 이후 Admin UI Budgets 에서 예산을 켜야 API 가 429 가 아닙니다.
set -euo pipefail

_ROOT="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=load_config.sh
source "$_ROOT/load_config.sh"

TEAM_INPUT=""
DEPT=""
DESCRIPTION="LLM Gateway team mapping"
ADD_USER_EMAIL=""
LIST_GROUPS=0

log()  { printf "\033[1;36m[add_team]\033[0m %s\n" "$*"; }
err()  { printf "\033[1;31m[add_team:err]\033[0m %s\n" "$*" >&2; }
ok()   { printf "\033[1;32m[add_team]\033[0m %s\n" "$*"; }
warn() { printf "\033[1;33m[add_team]\033[0m %s\n" "$*"; }

usage() {
  awk 'NR==1{next} /^[^#]/{exit} {sub(/^# ?/,""); print}' "$0"
  exit "${1:-0}"
}

while [ $# -gt 0 ]; do
  case "$1" in
    -h|--help) usage 0 ;;
    --list-groups) LIST_GROUPS=1; shift ;;
    --dept)
      [ $# -ge 2 ] || { err "--dept 뒤에 부서명이 필요합니다"; usage 1; }
      DEPT="$2"; shift 2
      ;;
    --description|--desc)
      [ $# -ge 2 ] || { err "--description 뒤에 값이 필요합니다"; usage 1; }
      DESCRIPTION="$2"; shift 2
      ;;
    --add-user)
      [ $# -ge 2 ] || { err "--add-user 뒤에 이메일이 필요합니다"; usage 1; }
      ADD_USER_EMAIL="$2"; shift 2
      ;;
    -*)
      err "알 수 없는 옵션: $1"; usage 1
      ;;
    *)
      if [ -z "$TEAM_INPUT" ]; then TEAM_INPUT="$1"; shift
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

if [ -z "$TEAM_INPUT" ]; then
  err "팀 이름(또는 전체 그룹명)이 필요합니다"
  usage 1
fi

PREFIX="${OIDC_GROUP_PREFIX}"

# 전체 그룹명 결정
if [ "${TEAM_INPUT#"$PREFIX"}" != "$TEAM_INPUT" ]; then
  # 이미 접두사 포함
  if [ -n "$DEPT" ]; then
    err "전체 그룹명($TEAM_INPUT)과 --dept 를 같이 쓰지 마세요"
    exit 1
  fi
  TEAM_GROUP="$TEAM_INPUT"
else
  if [ -n "$DEPT" ]; then
    case "$DEPT" in
      *_*)
        err "부서명에 underscore(_) 를 넣을 수 없습니다: $DEPT (하이픈 사용)"
        exit 1
        ;;
    esac
    case "$TEAM_INPUT" in
      *_*)
        err "팀명에 underscore(_) 를 넣을 수 없습니다: $TEAM_INPUT (하이픈 사용). 부서는 --dept"
        exit 1
        ;;
    esac
    TEAM_GROUP="${PREFIX}${DEPT}_${TEAM_INPUT}"
  else
    case "$TEAM_INPUT" in
      *_*)
        err "팀명에 underscore(_) 가 있으면 부서/팀으로 분리됩니다."
        err "  한 팀명: 하이픈 사용 → ./add_team.sh AWS-Users"
        err "  부서+팀: ./add_team.sh Users --dept AWS  → ${PREFIX}AWS_Users"
        exit 1
        ;;
    esac
    TEAM_GROUP="${PREFIX}${TEAM_INPUT}"
  fi
fi

if [ "$TEAM_GROUP" = "$ADMIN_GROUP" ]; then
  err "$ADMIN_GROUP 은 팀 그룹이 아닙니다 (Admin 전용). 팀 예: ${PREFIX}Backend"
  exit 1
fi

case "$TEAM_GROUP" in
  "${PREFIX}"*) ;;
  *)
    err "그룹명은 ${PREFIX} 로 시작해야 합니다 (현재: $TEAM_GROUP)"
    exit 1
    ;;
esac

# 접두사 제거 후 underscore 개수로 UI 결과 안내
TAIL="${TEAM_GROUP#"$PREFIX"}"
if [ -z "$TAIL" ]; then
  err "팀 꼬리가 비어 있습니다: $TEAM_GROUP"
  exit 1
fi
# bash: count underscores
US_COUNT="$(printf '%s' "$TAIL" | tr -cd '_' | wc -c | tr -d ' ')"
UI_HINT=""
case "$US_COUNT" in
  0) UI_HINT="Default Department → 팀 «${TAIL}»" ;;
  1)
    DEPT_PART="${TAIL%%_*}"
    TEAM_PART="${TAIL#*_}"
    UI_HINT="부서 «${DEPT_PART}» → 팀 «${TEAM_PART}»"
    ;;
  *)
    err "underscore 가 너무 많습니다 (허용 0~1, 접두사 제외). 현재: $TEAM_GROUP"
    exit 1
    ;;
esac

log "config=$GATEWAY_CONFIG"
log "region=$REGION pool=$USER_POOL_ID"
log "group=$TEAM_GROUP  ($UI_HINT)"

if aws cognito-idp get-group \
  --user-pool-id "$USER_POOL_ID" \
  --group-name "$TEAM_GROUP" >/dev/null 2>&1; then
  warn "이미 존재하는 그룹입니다: $TEAM_GROUP"
else
  log "Cognito 그룹 생성 중..."
  aws cognito-idp create-group \
    --user-pool-id "$USER_POOL_ID" \
    --group-name "$TEAM_GROUP" \
    --description "$DESCRIPTION" \
    --query 'Group.{Name:GroupName,Desc:Description}' --output table
  ok "그룹 생성 완료: $TEAM_GROUP"
  warn "Terraform 관리 환경이면 cognito_groups / tfvars 에도 같은 이름을 반영하세요 (drift 방지)."
fi

if [ -n "$ADD_USER_EMAIL" ]; then
  case "$ADD_USER_EMAIL" in
    *@*) ;;
    *) err "이메일 형식이 아닙니다: $ADD_USER_EMAIL"; exit 1 ;;
  esac
  if ! aws cognito-idp admin-get-user \
    --user-pool-id "$USER_POOL_ID" \
    --username "$ADD_USER_EMAIL" >/dev/null 2>&1; then
    err "사용자가 없습니다: $ADD_USER_EMAIL"
    err "먼저: ./add_user.sh $ADD_USER_EMAIL --team $TEAM_GROUP"
    exit 1
  fi
  log "사용자 그룹 배정: $ADD_USER_EMAIL → $TEAM_GROUP"
  aws cognito-idp admin-add-user-to-group \
    --user-pool-id "$USER_POOL_ID" \
    --username "$ADD_USER_EMAIL" \
    --group-name "$TEAM_GROUP"
  ok "그룹 배정 완료"
fi

echo
log "현재 그룹 목록:"
aws cognito-idp list-groups \
  --user-pool-id "$USER_POOL_ID" \
  --query 'Groups[].GroupName' --output table

echo
ok "다음 단계"
cat <<EOF

  Cognito 그룹:        $TEAM_GROUP
  Admin UI 예상 구조:  $UI_HINT

  1) 사용자 배정
     ./add_user.sh user@example.com --team $TEAM_GROUP
     ./add_user.sh user@example.com --existing --team $TEAM_GROUP

  2) DB 반영 (둘 중 하나)
     - 사용자 gateway-cli login
     - Admin UI → Users → Cognito 동기화

  3) Admin UI → Budgets 에서 팀 예산 활성화 (미설정 = 429)

  config: $GATEWAY_CONFIG

EOF
