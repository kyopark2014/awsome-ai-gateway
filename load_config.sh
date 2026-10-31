#!/usr/bin/env bash
# add_user.sh / add_apiKey.sh / add_team.sh / add_model.sh 가 공통으로 source 합니다.
# 설정은 스크립트와 같은 디렉터리의 config.json (또는 GATEWAY_CONFIG 경로)입니다.
# 이미 export 된 환경변수가 있으면 config 값보다 우선합니다.
#
# config.json 키:
#   aws_region, user_pool_id, oidc_client_id, oidc_issuer_url,
#   admin_api_url, anthropic_base_url, default_team_group, admin_group,
#   oidc_group_prefix, gateway_cli_tokens
#
# shellcheck 가 이 파일을 단독 검사할 때는 BASH_SOURCE 가 비어 있을 수 있습니다.
if [ -n "${_GATEWAY_CONFIG_LOADED:-}" ]; then
  return 0 2>/dev/null || true
fi
_GATEWAY_CONFIG_LOADED=1

_GATEWAY_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GATEWAY_CONFIG="${GATEWAY_CONFIG:-$_GATEWAY_ROOT/config.json}"

if [ ! -f "$GATEWAY_CONFIG" ]; then
  printf '\033[1;31m[config:err]\033[0m config 파일이 없습니다: %s\n' "$GATEWAY_CONFIG" >&2
  printf '\033[1;31m[config:err]\033[0m 같은 폴더에 config.json 을 두거나 GATEWAY_CONFIG 를 지정하세요.\n' >&2
  return 1 2>/dev/null || exit 1
fi

if ! command -v python3 >/dev/null 2>&1; then
  printf '\033[1;31m[config:err]\033[0m python3 가 필요합니다 (config.json 파싱)\n' >&2
  return 1 2>/dev/null || exit 1
fi

# env 가 비어 있을 때만 config 값을 채웁니다.
eval "$(
  GATEWAY_CONFIG="$GATEWAY_CONFIG" python3 - <<'PY'
import json, os, shlex
from pathlib import Path

path = Path(os.environ["GATEWAY_CONFIG"])
cfg = json.loads(path.read_text())

def get(*keys, default=""):
    for k in keys:
        if k in cfg and cfg[k] not in (None, ""):
            return str(cfg[k])
    return default

mapping = {
    "AWS_REGION": get("aws_region", "region", default="ap-northeast-2"),
    "USER_POOL_ID": get("user_pool_id"),
    "OIDC_CLIENT_ID": get("oidc_client_id", "client_id"),
    "OIDC_ISSUER_URL": get("oidc_issuer_url", "issuer_url"),
    "ADMIN_API_URL": get("admin_api_url"),
    "ANTHROPIC_BASE_URL": get("anthropic_base_url", "gateway_url"),
    "TEAM_GROUP": get("default_team_group", "team_group", default="Claude_AWS_Users"),
    "ADMIN_GROUP": get("admin_group", default="ClaudeAdmin"),
    "OIDC_GROUP_PREFIX": get("oidc_group_prefix", default="Claude_"),
    "GATEWAY_CLI_TOKENS": get("gateway_cli_tokens", default="~/.gateway-cli/oidc-tokens.json"),
}

home = str(Path.home())
for key, val in mapping.items():
    # 이미 환경에 값이 있으면 유지
    if os.environ.get(key):
        continue
    if not val:
        continue
    if val.startswith("~/"):
        val = home + val[1:]
    print(f"{key}={shlex.quote(val)}")
PY
)"

# REGION 별칭 + AWS CLI 기본 리전
REGION="${AWS_REGION:-${AWS_DEFAULT_REGION:-ap-northeast-2}}"
export AWS_REGION="$REGION" AWS_DEFAULT_REGION="$REGION"

# issuer 미기재 시 pool 로부터 생성
if [ -z "${OIDC_ISSUER_URL:-}" ] && [ -n "${USER_POOL_ID:-}" ]; then
  OIDC_ISSUER_URL="https://cognito-idp.${REGION}.amazonaws.com/${USER_POOL_ID}"
fi

export USER_POOL_ID OIDC_CLIENT_ID OIDC_ISSUER_URL ADMIN_API_URL ANTHROPIC_BASE_URL
export TEAM_GROUP ADMIN_GROUP OIDC_GROUP_PREFIX GATEWAY_CLI_TOKENS

_missing=0
for _req in USER_POOL_ID OIDC_CLIENT_ID ADMIN_API_URL; do
  if [ -z "${!_req:-}" ]; then
    printf '\033[1;31m[config:err]\033[0m %s 가 비어 있습니다. config.json 을 확인하세요: %s\n' "$_req" "$GATEWAY_CONFIG" >&2
    _missing=1
  fi
done
if [ "$_missing" = "1" ]; then
  return 1 2>/dev/null || exit 1
fi

unset _req _missing
