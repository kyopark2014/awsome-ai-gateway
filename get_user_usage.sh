#!/usr/bin/env bash
# 사용자의 사용 현황(월 합계·모델별·일별·예산)을 조회합니다.
#
# 모드 1: 본인 조회 (--self, 권장 — 관리자 권한/서비스 토큰 불필요)
#   캐시된 **본인** id_token (~/.gateway-cli/oidc-tokens.json) 으로 admin-api 의
#   GET /admin/my/budget·/admin/my/usage 를 직접 호출합니다. 이 두 엔드포인트는
#   사용자 포털(html/, /portal/budget·/portal/usage)이 Google 로그인 뒤 그대로
#   호출하는 것과 **같은 함수**라, 포털 화면과 정확히 같은 숫자가 나옵니다.
#   토큰이 없거나 만료됐으면 config.json 의 oidc_issuer_url/oidc_client_id 로
#   `gateway-cli login` 을 자동 실행합니다(브라우저가 뜨므로 대화형 세션 필요).
#
#   ./get_user_usage.sh --self
#   ./get_user_usage.sh --self --period 2026-10
#   ./get_user_usage.sh --self --json
#
# 이메일로 호출 (./get_user_usage.sh <email>) 하면 자동으로 판단합니다:
#   * 캐시된 로그인(~/.gateway-cli/oidc-tokens.json)의 이메일과 같으면 → 모드 1(본인 조회)로
#     처리합니다. 관리자 권한도 서비스 토큰도 필요 없습니다.
#   * 다르면(또는 로그인 캐시가 없으면) → 모드 2(관리자 조회)로 넘어갑니다.
#
# 모드 2: 다른 사용자 조회 (관리자 권한 필요)
#   /admin/my/* 는 토큰 주인 본인만 볼 수 있으므로, 관리자용 엔드포인트
#   (users · analytics/usage/* · budgets/summary)를 조합해 같은 정보를 만듭니다.
#
#   ./get_user_usage.sh other@example.com
#   ./get_user_usage.sh other@example.com --period 2026-10
#   ./get_user_usage.sh other@example.com --json
#   ./get_user_usage.sh other@example.com --no-daily       # 일별 생략(빠름)
#
#   서비스 토큰 (ADMIN 권한, 최초 1회 발급):
#     ./get_user_usage.sh --issue-token --admin-email admin@example.com --password '…'
#     ./get_user_usage.sh --issue-token                         # gateway-cli login 한 관리자 캐시 사용
#     옵션: --token-name NAME  --token-days N(기본 서버값 90)  --print-token
#     발급된 토큰은 ~/.gateway-cli/service-token (0600) 에 저장되고 이후 자동 사용됩니다.
#
#   토큰 우선순위: GATEWAY_SERVICE_TOKEN 환경변수 > 저장 파일(GATEWAY_SERVICE_TOKEN_FILE)
#
# 설정: 같은 폴더의 config.json (또는 GATEWAY_CONFIG=/path/to/config.json)
#
# 참고:
#  * --self 는 서버가 직접 계산한 값(/admin/my/*)을 그대로 보여줍니다 — 가장 정확합니다.
#  * 모드 2 의 일별은 by-user 누적값(1일~D일)을 날짜마다 호출해 차분합니다(조회 일수만큼 호출).
#    금액은 admin-ui 분석 화면과 같은 집계(SUCCESS · KST · 이관 seed 포함)라
#    /admin/my/budget 의 used_usd 와는 seed 처리 때문에 다를 수 있습니다 — --self 를 쓰세요.
set -euo pipefail

_ROOT="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=load_config.sh
source "$_ROOT/load_config.sh"

EMAIL=""
PERIOD=""
JSON_OUT=0
NO_DAILY=0
ISSUE=0
SELF_MODE=0
ADMIN_EMAIL=""
PASSWORD="${COGNITO_PASSWORD:-}"
ADMIN_TOKEN_FILE=""
TOKEN_NAME=""
TOKEN_DAYS=""
PRINT_TOKEN=0
SVC_TOKEN_FILE="${GATEWAY_SERVICE_TOKEN_FILE:-$HOME/.gateway-cli/service-token}"

log()  { printf "\033[1;36m[get_user_usage]\033[0m %s\n" "$*" >&2; }
err()  { printf "\033[1;31m[get_user_usage:err]\033[0m %s\n" "$*" >&2; }
ok()   { printf "\033[1;32m[get_user_usage]\033[0m %s\n" "$*" >&2; }

usage() {
  awk 'NR==1{next} /^[^#]/{exit} {sub(/^# ?/,""); print}' "$0"
  exit "${1:-0}"
}

need_val() { [ $# -ge 2 ] || { err "$1 뒤에 값이 필요합니다"; usage 1; }; }

while [ $# -gt 0 ]; do
  case "$1" in
    -h|--help) usage 0 ;;
    --period)      need_val "$@"; PERIOD="$2"; shift 2 ;;
    --json)        JSON_OUT=1; shift ;;
    --no-daily)    NO_DAILY=1; shift ;;
    --issue-token) ISSUE=1; shift ;;
    --self)        SELF_MODE=1; shift ;;
    --admin-email) need_val "$@"; ADMIN_EMAIL="$2"; shift 2 ;;
    --password)    need_val "$@"; PASSWORD="$2"; shift 2 ;;
    --token-file)  need_val "$@"; ADMIN_TOKEN_FILE="$2"; shift 2 ;;
    --token-name)  need_val "$@"; TOKEN_NAME="$2"; shift 2 ;;
    --token-days)  need_val "$@"; TOKEN_DAYS="$2"; shift 2 ;;
    --print-token) PRINT_TOKEN=1; shift ;;
    -*) err "알 수 없는 옵션: $1"; usage 1 ;;
    *)
      if [ -z "$EMAIL" ]; then EMAIL="$1"; shift
      else err "인자가 너무 많습니다: $1"; usage 1
      fi
      ;;
  esac
done

for cmd in python3 curl; do
  command -v "$cmd" >/dev/null 2>&1 || { err "$cmd 가 필요합니다"; exit 1; }
done

# 이메일로 호출됐고 --self 는 안 썼을 때, 캐시된 로그인 계정의 이메일과 같으면
# 자동으로 본인 조회(모드 1)로 전환한다. exp 는 보지 않는다 — 만료돼 있어도
# "누구 계정인지"만 보고, 실제 로그인/재로그인은 모드 1 쪽에서 처리한다.
if [ "$SELF_MODE" != "1" ] && [ -n "$EMAIL" ] && [ -f "$GATEWAY_CLI_TOKENS" ]; then
  TOKEN_EMAIL="$(python3 -c '
import base64, json, sys
try:
    data = json.load(open(sys.argv[1]))
    tok = data.get("id_token") or data.get("IdToken")
    if not tok:
        raise SystemExit
    payload = tok.split(".")[1]
    payload += "=" * ((4 - len(payload) % 4) % 4)
    claims = json.loads(base64.urlsafe_b64decode(payload))
    print(claims.get("email", "") or "")
except Exception:
    pass
' "$GATEWAY_CLI_TOKENS" 2>/dev/null || true)"
  if [ -n "$TOKEN_EMAIL" ]; then
    LOWER_EMAIL="$(printf '%s' "$EMAIL" | tr '[:upper:]' '[:lower:]')"
    LOWER_TOKEN_EMAIL="$(printf '%s' "$TOKEN_EMAIL" | tr '[:upper:]' '[:lower:]')"
    if [ "$LOWER_EMAIL" = "$LOWER_TOKEN_EMAIL" ]; then
      log "$EMAIL 은 캐시된 로그인 계정 본인입니다 — 관리자 권한 없이 본인 조회로 처리합니다"
      SELF_MODE=1
    fi
  fi
fi

# ───────────────────────── 서비스 토큰 발급 ─────────────────────────
# 관리자(ClaudeAdmin) 의 Cognito id_token 이 필요합니다. 서비스 토큰은 새 서비스 토큰을
# 발급할 수 없습니다(서버 규칙) — 사람 관리자만 발급합니다.
ID_TOKEN=""

obtain_id_token_password() {
  command -v aws >/dev/null 2>&1 || { err "aws CLI 가 필요합니다"; return 1; }
  log "USER_PASSWORD_AUTH 로 관리자 id_token 요청..."
  local resp
  if ! resp="$(aws cognito-idp initiate-auth \
    --auth-flow USER_PASSWORD_AUTH \
    --client-id "$OIDC_CLIENT_ID" \
    --auth-parameters USERNAME="$ADMIN_EMAIL",PASSWORD="$PASSWORD" \
    --output json 2>&1)"; then
    err "initiate-auth 실패"
    printf '%s\n' "$resp" >&2
    return 1
  fi
  if printf '%s' "$resp" | grep -q ChallengeName; then
    err "추가 챌린지가 필요합니다. gateway-cli login 으로 비밀번호를 확정하세요."
    return 1
  fi
  ID_TOKEN="$(printf '%s' "$resp" | python3 -c 'import sys,json; print(json.load(sys.stdin)["AuthenticationResult"]["IdToken"])')"
}

obtain_id_token_file() {
  local f="$1"
  [ -f "$f" ] || return 1
  log "토큰 파일에서 id_token 확인: $f"
  ID_TOKEN="$(WANT_EMAIL="$ADMIN_EMAIL" TOKEN_FILE="$f" python3 - <<'PY'
import base64, json, os, sys, time
data = json.load(open(os.environ["TOKEN_FILE"]))
tok = data.get("id_token") or data.get("IdToken")
if not tok:
    sys.exit(2)
payload = tok.split(".")[1]
payload += "=" * ((4 - len(payload) % 4) % 4)
claims = json.loads(base64.urlsafe_b64decode(payload))
want = os.environ.get("WANT_EMAIL", "")
if want and claims.get("email") != want:
    print(f"email mismatch: token={claims.get('email')!r} want={want!r}", file=sys.stderr)
    sys.exit(3)
if int(claims.get("exp") or 0) < int(time.time()) + 30:
    print("id_token expired", file=sys.stderr)
    sys.exit(4)
print(tok)
PY
)" || return 1
}

issue_service_token() {
  if [ -n "$PASSWORD" ]; then
    [ -n "$ADMIN_EMAIL" ] || { err "--password 를 쓰려면 --admin-email 이 필요합니다"; exit 1; }
    obtain_id_token_password || exit 1
  elif [ -n "$ADMIN_TOKEN_FILE" ]; then
    obtain_id_token_file "$ADMIN_TOKEN_FILE" || { err "관리자 토큰 파일을 쓸 수 없습니다: $ADMIN_TOKEN_FILE"; exit 1; }
  elif obtain_id_token_file "$GATEWAY_CLI_TOKENS"; then
    ok "캐시된 gateway-cli id_token 사용"
  else
    err "관리자 id_token 이 없습니다. 다음 중 하나를 사용하세요:"
    err "  ./get_user_usage.sh --issue-token --admin-email <관리자> --password '…'"
    err "  관리자 계정으로 gateway-cli login 후 ./get_user_usage.sh --issue-token"
    exit 1
  fi

  [ -n "$TOKEN_NAME" ] || TOKEN_NAME="get_user_usage-$(hostname -s 2>/dev/null || echo host)-$(date +%Y%m%d)"
  local body url http_body http_code
  body="$(NAME="$TOKEN_NAME" DAYS="$TOKEN_DAYS" python3 -c '
import json, os
b = {"name": os.environ["NAME"]}
if os.environ.get("DAYS"):
    b["expiry_days"] = int(os.environ["DAYS"])
print(json.dumps(b))')"
  url="${ADMIN_API_URL%/}/admin/service-tokens"
  log "POST $url (name=$TOKEN_NAME)"

  http_body="$(mktemp)"
  http_code="$(curl -sS -o "$http_body" -w '%{http_code}' -X POST "$url" \
    -H "Authorization: Bearer ${ID_TOKEN}" \
    -H "Content-Type: application/json" \
    -d "$body")" || true

  if [ "$http_code" != "200" ] && [ "$http_code" != "201" ]; then
    err "서비스 토큰 발급 실패 HTTP $http_code"
    case "$http_code" in
      403) err "ADMIN 권한이 필요합니다 (그룹 $ADMIN_GROUP 또는 DB role=ADMIN)" ;;
    esac
    cat "$http_body" >&2 || true; echo >&2
    rm -f "$http_body"
    exit 1
  fi

  local tok exp
  tok="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("token") or "")' "$http_body")"
  exp="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("expires_at") or "")' "$http_body")"
  rm -f "$http_body"
  [ -n "$tok" ] || { err "응답에 token 이 없습니다"; exit 1; }

  mkdir -p "$(dirname "$SVC_TOKEN_FILE")"
  ( umask 077; printf '%s\n' "$tok" >"$SVC_TOKEN_FILE" )
  chmod 600 "$SVC_TOKEN_FILE"
  ok "서비스 토큰 발급 완료 (만료: $exp)"
  ok "저장: $SVC_TOKEN_FILE (0600) — 원문은 서버에서 다시 볼 수 없습니다"
  if [ "$PRINT_TOKEN" = "1" ]; then
    printf '%s\n' "$tok"
  fi
}

if [ "$ISSUE" = "1" ]; then
  issue_service_token
  exit 0
fi

# ───────────────────────── 모드 1: 본인 조회 (--self) ─────────────────────────
# Google 포털과 똑같이 /admin/my/* 를 호출한다 — 다른 것은 토큰 발급 수단(Cognito id_token)뿐이다.
if [ "$SELF_MODE" = "1" ]; then
  [ -n "$PERIOD" ] && ! printf '%s' "$PERIOD" | grep -qE '^[0-9]{4}-(0[1-9]|1[0-2])$' \
    && { err "--period 는 YYYY-MM 형식이어야 합니다: $PERIOD"; exit 1; }

  SELF_TOKEN_FILE="${ADMIN_TOKEN_FILE:-$GATEWAY_CLI_TOKENS}"
  if ! obtain_id_token_file "$SELF_TOKEN_FILE"; then
    # config.json(load_config.sh 가 이미 읽어 export 한 OIDC_ISSUER_URL/OIDC_CLIENT_ID)으로
    # gateway-cli login 을 자동 실행한다. 브라우저가 뜨므로 대화형 세션이 필요하다.
    command -v gateway-cli >/dev/null 2>&1 || {
      err "본인 id_token 이 없고(만료/로그인 전) gateway-cli 도 설치돼 있지 않습니다."
      err "  설치 후: gateway-cli login --issuer-url \"$OIDC_ISSUER_URL\" --client-id \"$OIDC_CLIENT_ID\""
      exit 1
    }
    log "본인 id_token 이 없거나 만료됐습니다 — config.json 값으로 gateway-cli login 실행..."
    log "  issuer=$OIDC_ISSUER_URL client=$OIDC_CLIENT_ID"
    gateway-cli login --issuer-url "$OIDC_ISSUER_URL" --client-id "$OIDC_CLIENT_ID" || {
      err "gateway-cli login 실패"
      exit 1
    }
    obtain_id_token_file "$SELF_TOKEN_FILE" || {
      err "로그인 후에도 유효한 id_token 을 읽을 수 없습니다: $SELF_TOKEN_FILE"
      exit 1
    }
  fi
  SELF_ID_TOKEN="$ID_TOKEN"

  log "admin_api=$ADMIN_API_URL mode=self period=${PERIOD:-현재월(KST)}"

  SELF_ID_TOKEN="$SELF_ID_TOKEN" PERIOD="$PERIOD" JSON_OUT="$JSON_OUT" \
  BASE_URL="${ADMIN_API_URL%/}" python3 - <<'PY'
import json
import os
import sys
import urllib.error
import urllib.parse
import urllib.request
from decimal import Decimal

BASE = os.environ["BASE_URL"]
TOKEN = os.environ["SELF_ID_TOKEN"]
PERIOD = os.environ.get("PERIOD") or ""
JSON_OUT = os.environ["JSON_OUT"] == "1"


def die(msg: str, code: int = 1):
    print(f"\033[1;31m[get_user_usage:err]\033[0m {msg}", file=sys.stderr)
    sys.exit(code)


def get(path: str, params: dict | None = None):
    url = BASE + path
    if params:
        url += "?" + urllib.parse.urlencode(params)
    req = urllib.request.Request(url, headers={"Authorization": f"Bearer {TOKEN}"})
    try:
        with urllib.request.urlopen(req, timeout=30) as r:
            return json.load(r)
    except urllib.error.HTTPError as e:
        body = e.read().decode("utf-8", "replace")[:500]
        if e.code == 401:
            die(f"401 인증 실패 — 토큰이 만료됐을 수 있습니다. gateway-cli login 후 재시도.\n{body}")
        if e.code == 403:
            die(f"403: {body}")
        die(f"HTTP {e.code} {path}\n{body}")
    except urllib.error.URLError as e:
        die(f"연결 실패 {url}: {e.reason}")


D = lambda v: Decimal(str(v if v is not None else 0))

params = {"period": PERIOD} if PERIOD else None
budget = get("/admin/my/budget")
usage = get("/admin/my/usage", params)

out = {"budget": budget, "usage": usage}
if JSON_OUT:
    print(json.dumps(out, ensure_ascii=False, indent=2))
    sys.exit(0)


def usd(v, n=4):
    return "-" if v is None else f"${D(v):,.{n}f}"


b = budget["budget"]
team = budget.get("team", {})
print()
print(f"사용자  user_id={budget['user_id']}")
print(f"기간    {usage['period']} (KST)")
print("=" * 78)
print("개인 예산")
if b.get("configured"):
    print(f"  한도 {usd(b['limit_usd'], 2)}   사용 {usd(b['used_usd'])}   "
          f"잔여 {usd(b['remaining_usd'])}   사용률 {b['usage_pct']}%   정책 {b['policy']}")
else:
    print(f"  미설정 (팀 예산 적용)   사용 {usd(b['used_usd'])}")
print("팀 예산")
if team.get("assigned"):
    state = "소진" if team.get("budget_exhausted") else ("설정됨" if team.get("budget_configured") else "미설정")
    print(f"  팀 배정됨   상태: {state}")
else:
    print("  팀 미배정")
print()
print("월 합계 (이번 달 1일 ~ 오늘)")
days = usage.get("daily_usage", [])
total_cost = sum(D(d["cost_usd"]) for d in days)
total_calls = sum(d["requests"] for d in days)
total_tokens = sum(d["tokens"] for d in days)
print(f"  비용 {usd(total_cost)}   호출 {total_calls:,}   토큰 {total_tokens:,}")
print()
print("모델별")
by_model = usage.get("by_model", [])
if by_model:
    print(f"  {'model':<34}{'cost':>12}{'calls':>9}{'tokens':>13}")
    for r in by_model:
        print(f"  {r['model_alias']:<34}{usd(r['cost_usd']):>12}{r['requests']:>9,}{r['tokens']:>13,}")
else:
    print("  (사용 내역 없음)")
print()
print("일별")
if days:
    print(f"  {'date':<12}{'cost':>12}{'calls':>9}{'tokens':>13}")
    for d in days:
        print(f"  {d['date']:<12}{usd(d['cost_usd']):>12}{d['requests']:>9,}{d['tokens']:>13,}")
else:
    print("  (사용 내역 없음)")
print()
PY
  exit 0
fi

# ───────────────────────── 모드 2: 다른 사용자 조회 (관리자 권한) ─────────────────────────
if [ -z "$EMAIL" ]; then
  err "이메일이 필요합니다"
  usage 1
fi
case "$EMAIL" in
  *@*.*) ;;
  *) err "이메일 형식이 아닙니다: $EMAIL"; exit 1 ;;
esac
if [ -n "$PERIOD" ] && ! printf '%s' "$PERIOD" | grep -qE '^[0-9]{4}-(0[1-9]|1[0-2])$'; then
  err "--period 는 YYYY-MM 형식이어야 합니다: $PERIOD"
  exit 1
fi

SVC_TOKEN="${GATEWAY_SERVICE_TOKEN:-}"
if [ -z "$SVC_TOKEN" ] && [ -f "$SVC_TOKEN_FILE" ]; then
  SVC_TOKEN="$(head -n1 "$SVC_TOKEN_FILE" | tr -d '[:space:]')"
fi
if [ -z "$SVC_TOKEN" ]; then
  err "서비스 토큰이 없습니다. 먼저 발급하세요:"
  err "  ./get_user_usage.sh --issue-token --admin-email <관리자> --password '…'"
  err "또는 GATEWAY_SERVICE_TOKEN 환경변수 / $SVC_TOKEN_FILE 를 준비하세요."
  exit 1
fi
case "$SVC_TOKEN" in
  svc-*) ;;
  *) err "서비스 토큰 형식이 아닙니다 (svc- 로 시작해야 함)"; exit 1 ;;
esac

log "admin_api=$ADMIN_API_URL email=$EMAIL period=${PERIOD:-현재월(KST)}"

# 토큰은 argv 가 아니라 환경변수로 넘긴다(ps 노출 방지).
SVC_TOKEN="$SVC_TOKEN" TARGET_EMAIL="$EMAIL" PERIOD="$PERIOD" \
JSON_OUT="$JSON_OUT" NO_DAILY="$NO_DAILY" BASE_URL="${ADMIN_API_URL%/}" \
python3 - <<'PY'
import calendar
import json
import os
import re
import sys
import urllib.error
import urllib.parse
import urllib.request
from concurrent.futures import ThreadPoolExecutor
from datetime import date, datetime
from decimal import Decimal
from zoneinfo import ZoneInfo

BASE = os.environ["BASE_URL"]
TOKEN = os.environ["SVC_TOKEN"]
EMAIL = os.environ["TARGET_EMAIL"].strip()
JSON_OUT = os.environ["JSON_OUT"] == "1"
NO_DAILY = os.environ["NO_DAILY"] == "1"


def die(msg: str, code: int = 1):
    print(f"\033[1;31m[get_user_usage:err]\033[0m {msg}", file=sys.stderr)
    sys.exit(code)


def get(path: str, params: dict | None = None):
    url = BASE + path
    if params:
        url += "?" + urllib.parse.urlencode(params)
    req = urllib.request.Request(url, headers={"Authorization": f"Bearer {TOKEN}"})
    try:
        with urllib.request.urlopen(req, timeout=30) as r:
            return json.load(r)
    except urllib.error.HTTPError as e:
        body = e.read().decode("utf-8", "replace")[:500]
        if e.code == 401:
            die(f"401 인증 실패 — 서비스 토큰이 만료/폐기됐을 수 있습니다. 재발급: --issue-token\n{body}")
        if e.code == 403:
            die(f"403 권한 없음 (ADMIN 필요): {path}\n{body}")
        die(f"HTTP {e.code} {path}\n{body}")
    except urllib.error.URLError as e:
        die(f"연결 실패 {url}: {e.reason}")


D = lambda v: Decimal(str(v if v is not None else 0))

# ── 기간 (KST) ──
today = datetime.now(ZoneInfo("Asia/Seoul")).date()
period = os.environ.get("PERIOD") or today.strftime("%Y-%m")
y, m = (int(x) for x in period.split("-"))
first = date(y, m, 1)
if first > today.replace(day=1):
    die(f"미래 기간입니다: {period}")
last_day = calendar.monthrange(y, m)[1]
end = min(date(y, m, last_day), today)
end_s = end.isoformat()

# ── ① 사용자 ──
res = get("/admin/users", {"email": EMAIL})
items = [u for u in res.get("items", []) if (u.get("email") or "").lower() == EMAIL.lower()]
if not items:
    die(f"DB 에 사용자가 없습니다: {EMAIL}\n"
        "  Cognito 에만 있고 아직 로그인/동기화 전일 수 있습니다 (gateway-cli login 또는 Admin UI → Cognito 동기화).")
user = items[0]
uid = user["id"]
team_id = user.get("team_id")

# ── ② 월 합계 / ③ 모델별 ──
def by_user_row(date_s: str):
    r = get("/admin/analytics/usage/by-user", {"period": period, "date": date_s})
    for it in r.get("items", []):
        if it.get("user_id") == uid:
            return it
    return None


def num(row, key):
    return D(row.get(key)) if row else Decimal(0)


total_row = by_user_row(end_s)
seeded = num(total_row, "seeded_usd")
summary = {
    "cost_usd": str(num(total_row, "cost_usd")),
    "seeded_usd": str(seeded),
    "calls": int(num(total_row, "calls")),
    "input_tokens": int(num(total_row, "input_tokens")),
    "output_tokens": int(num(total_row, "output_tokens")),
    "cache_read_tokens": int(num(total_row, "cache_read_tokens")),
    "cache_write_tokens": int(num(total_row, "cache_write_tokens")),
}

mres = get("/admin/analytics/usage/by-user-model", {"period": period, "date": end_s})
by_model = [
    {
        "model_alias": it["model_alias"],
        "cost_usd": str(D(it["cost_usd"])),
        "calls": it["calls"],
        "input_tokens": it["input_tokens"],
        "output_tokens": it["output_tokens"],
        "cache_read_tokens": it["cache_read_tokens"],
        "cache_write_tokens": it["cache_write_tokens"],
        "avg_latency_ms": it["avg_latency_ms"],
    }
    for it in mres.get("items", [])
    if it.get("user_id") == uid
]
by_model.sort(key=lambda r: D(r["cost_usd"]), reverse=True)

# ── 일별: by-user 는 "1일~D일 누적" 이라 날짜마다 호출해 차분한다 ──
daily = []
if not NO_DAILY:
    days = [first.replace(day=d).isoformat() for d in range(1, end.day + 1)]
    if len(days) > 1:
        print(f"[get_user_usage] 일별 조회: {len(days)}회 호출 중...", file=sys.stderr)
    with ThreadPoolExecutor(max_workers=6) as ex:
        rows = list(ex.map(by_user_row, days))
    keys = ["cost_usd", "calls", "input_tokens", "output_tokens", "cache_read_tokens", "cache_write_tokens"]
    # cost_usd 에는 월 상수 seed 가 매일 포함돼 있으므로 기준선(day 0)을 seed 로 둔다.
    prev = {k: Decimal(0) for k in keys}
    prev["cost_usd"] = seeded
    for d_s, row in zip(days, rows):
        cur = {k: num(row, k) for k in keys}
        if row is None:
            cur["cost_usd"] = seeded
        diff = {k: cur[k] - prev[k] for k in keys}
        prev = cur
        if diff["calls"] or diff["cost_usd"]:
            daily.append({
                "date": d_s,
                "cost_usd": str(diff["cost_usd"]),
                "calls": int(diff["calls"]),
                "input_tokens": int(diff["input_tokens"]),
                "output_tokens": int(diff["output_tokens"]),
                "cache_read_tokens": int(diff["cache_read_tokens"]),
                "cache_write_tokens": int(diff["cache_write_tokens"]),
            })

# ── 예산 (개인 / 팀) ──
def budget_for(scope: str, target: str):
    r = get("/admin/budgets/summary", {"scope": scope, "target_id": target, "period": period})
    for it in r.get("summary", []):
        if it.get("target_id") == target:
            return {
                "target_name": it.get("target_name"),
                "limit_usd": None if it.get("limit_usd") is None else str(D(it["limit_usd"])),
                "used_usd": str(D(it.get("used_usd"))),
                "remaining_usd": None if it.get("remaining_usd") is None else str(D(it["remaining_usd"])),
                "usage_pct": None if it.get("usage_pct") is None else str(D(it["usage_pct"])),
                "is_active": it.get("is_active"),
            }
    return None


user_budget = budget_for("USER", uid)
team_budget = budget_for("TEAM", team_id) if team_id else None

out = {
    "user": {
        "id": uid,
        "email": user.get("email"),
        "display_name": user.get("display_name"),
        "role": user.get("role"),
        "team_id": team_id,
        "team_name": user.get("team_name"),
        "is_active": user.get("is_active"),
    },
    "period": period,
    "through": end_s,
    "summary": summary,
    "by_model": by_model,
    "daily": daily,
    "budget": user_budget,
    "team_budget": team_budget,
}

if JSON_OUT:
    print(json.dumps(out, ensure_ascii=False, indent=2))
    sys.exit(0)


# ── 사람이 읽는 출력 ──
def usd(v, n=4):
    return "-" if v is None else f"${D(v):,.{n}f}"


def budget_lines(label, b):
    if b is None:
        print(f"  {label}: (조회 결과 없음)")
    elif b["limit_usd"] is None:
        print(f"  {label}: 예산 미설정   사용 {usd(b['used_usd'])}")
    else:
        pct = "-" if b["usage_pct"] is None else f"{D(b['usage_pct']):.1f}%"
        print(f"  {label}: 한도 {usd(b['limit_usd'], 2)}   사용 {usd(b['used_usd'])}   "
              f"잔여 {usd(b['remaining_usd'])}   사용률 {pct}")


u = out["user"]
print()
print(f"사용자  {u['display_name']} <{u['email']}>   팀 {u['team_name'] or '-'}   "
      f"role {u['role']}   {'활성' if u['is_active'] else '비활성'}")
print(f"기간    {period} (KST, {first.isoformat()} ~ {end_s})")
print("=" * 78)
print("월 합계")
tot = summary
print(f"  비용 {usd(tot['cost_usd'])}   호출 {tot['calls']:,}   "
      f"in {tot['input_tokens']:,} / out {tot['output_tokens']:,} / "
      f"cache-r {tot['cache_read_tokens']:,} / cache-w {tot['cache_write_tokens']:,}")
if D(tot["seeded_usd"]) > 0:
    print(f"  (이관 주입분 {usd(tot['seeded_usd'])} 포함)")
print()
print("예산")
budget_lines("개인", user_budget)
budget_lines("팀  ", team_budget)
print()
print("모델별")
if by_model:
    print(f"  {'model':<34}{'cost':>12}{'calls':>9}{'in':>13}{'out':>12}")
    for r in by_model:
        print(f"  {r['model_alias']:<34}{usd(r['cost_usd']):>12}{r['calls']:>9,}"
              f"{r['input_tokens']:>13,}{r['output_tokens']:>12,}")
else:
    print("  (사용 내역 없음)")
if not NO_DAILY:
    print()
    print("일별")
    if daily:
        print(f"  {'date':<12}{'cost':>12}{'calls':>9}{'in':>13}{'out':>12}")
        for r in daily:
            print(f"  {r['date']:<12}{usd(r['cost_usd']):>12}{r['calls']:>9,}"
                  f"{r['input_tokens']:>13,}{r['output_tokens']:>12,}")
    else:
        print("  (사용 내역 없음)")
print()
PY
