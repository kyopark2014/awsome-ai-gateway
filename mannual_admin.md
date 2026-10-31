# Admin 운영 매뉴얼 (수동)

Admin UI / Cognito 기준 운영 절차입니다. 상세·전체 권한 범위는 [`guides/admin-guide.md`](guides/admin-guide.md)를 참고하세요.

---

## 팀 추가

팀은 Admin UI에서 “팀 만들기”로 만들지 않습니다.  
**Cognito 그룹을 만들고** → 사용자를 넣고 → **첫 로그인(또는 Cognito 동기화)** 으로 DB에 팀이 생긴 뒤 → **Admin UI에서 예산을 켭니다.**

### 원칙

| 무엇 | 어디서 | 비고 |
|------|--------|------|
| 팀 신원 (그룹명) | **Cognito Groups** | `Claude_<팀명>` |
| DB 팀/사용자 행 | **자동** | 첫 OIDC 로그인 또는 Cognito 동기화 |
| 예산·Rate Limit | **Admin UI** | 미설정 시 요청 **429** (기본 $0 HARD_BLOCK) |
| 모델 등록 | **Admin UI** 또는 `./add_model.sh` | DB `model.model_aliases` (INACTIVE면 404) |

### 그룹 명명 규칙

접두사 기본값: `Claude_` (`OIDC_GROUP_PREFIX`)

| 그룹명 예 | 결과 |
|-----------|------|
| `Claude_Backend` | Default Department → 팀 `Backend` |
| `Claude_AI-Center_Backend` | 부서 `AI-Center` → 팀 `Backend` |
| `ClaudeAdmin` | 팀 아님 (Admin 권한 그룹) |

- 팀/부서 이름에 underscore 세그먼트 주의 — `Claude_AWS_Users`는 부서 `AWS` + 팀 `Users` (하이픈이면 한 팀명, 예: `Claude_AWS-Users`)
- `Claude_*` 팀 그룹이 없으면 VK 발급 시 `403 no_matching_team_group`
- Admin 계정도 **팀 그룹에 반드시** 넣습니다 (`ClaudeAdmin`만으로는 부족)

### 1) Cognito에 그룹 만들기

**방법 A — `add_team.sh` (권장, 즉시)**

`config.json`의 pool/prefix를 사용합니다. 다른 서버는 config만 바꾸면 됩니다.

```bash
./add_team.sh Backend                    # → Claude_Backend
./add_team.sh AWS-Users                  # → Claude_AWS-Users (한 팀명, 하이픈)
./add_team.sh Users --dept AWS           # → Claude_AWS_Users (부서 AWS / 팀 Users)
./add_team.sh Backend --add-user user@example.com
./add_team.sh --list-groups
```

**방법 B — Terraform (IaC)**

```bash
cd deployment/terraform/environments/llm-gateway-prod   # 또는 해당 ENV
# terraform.tfvars 의 cognito_groups 에 "Claude_NewTeam" 추가
terraform apply
```

**방법 C — AWS CLI**

```bash
export AWS_REGION=ap-northeast-2 AWS_DEFAULT_REGION=ap-northeast-2
USER_POOL_ID="ap-northeast-2_xa33nFlY3"   # prod 예 — terraform output / config.json

aws cognito-idp create-group \
  --user-pool-id "$USER_POOL_ID" \
  --group-name "Claude_NewTeam" \
  --description "LLM Gateway team mapping"
```

방법 A/C 사용 후 Terraform 관리 환경이면 tfvars에도 같은 그룹을 반영하세요 (drift 방지).

### 2) 사용자 배정

신규 사용자·기존 사용자 그룹 배정·팀 이동은 아래 [사용자 추가 및 팀 변경 방법](#사용자-추가-및-팀-변경-방법)을 따릅니다.

### 3) DB에 팀 반영

둘 중 하나면 됩니다.

1. **사용자**가 `gateway-cli login` (또는 첫 API/exchange) — 팀·사용자 자동 INSERT  
2. **Admin**이 이미 로그인한 뒤 Admin UI → Users → **Cognito 동기화**

전제: `COGNITO_USER_POOL_ID`가 admin-api에 설정되어 있어야 동기화가 동작합니다.

### 4) Admin UI에서 예산 활성화 (필수)

자동 생성 팀은 기본 **$0 + HARD_BLOCK**이라, 켜기 전에는 해당 팀 API가 **429**입니다.

1. Admin UI 접속: **https://admin.my-agentic-ai.click** ([`admin-ui.md`](admin-ui.md))  
2. 진입: https://admin.my-agentic-ai.click/api/auth/login (callback URL을 직접 열지 말 것)  
3. **Budgets** (또는 Teams) → 새 팀 선택 → **Edit**  
4. 예: `max_budget_usd` $100~500, `policy` `HARD_BLOCK`, alert `[80, 90, 100]`

필요 시 같은 화면에서 팀별 **허용 모델**, **Rate Limit**도 설정합니다.

---

## 모델 추가

모델 허용 목록은 **DB 주도**입니다. Admin UI Models 또는 `./add_model.sh`로 alias를 등록합니다.

### `add_model.sh` (권장, CLI)

`config.json`의 `admin_api_url`을 사용합니다. **ClaudeAdmin** 역할 사용자의 Cognito `id_token`이 필요합니다.

```bash
# 목록
./add_model.sh --list --email admin@example.com --password '…'
# 또는 gateway-cli login 후
./add_model.sh --list --email admin@example.com

# Claude(Bedrock native) 등록 예
./add_model.sh claude-sonnet-4-6 \
  --preset bedrock \
  --provider-model-id global.anthropic.claude-sonnet-4-6 \
  --input-price 0.003 --output-price 0.015 \
  --cache-5m-price 0.00375 --cache-read-price 0.0003 \
  --email admin@example.com --password '…'

# GPT (bedrock-runtime OpenAI 호환) 예
./add_model.sh gpt-6-astra \
  --preset bedrock-runtime-openai \
  --provider-model-id us.openai.gpt-6-astra \
  --endpoint-url https://bedrock-runtime.us-east-2.amazonaws.com \
  --input-price 0.002 --output-price 0.008 \
  --email admin@example.com --password '…'

# 활성/비활성
./add_model.sh claude-sonnet-4-6 --deactivate --email admin@example.com --password '…'
./add_model.sh claude-sonnet-4-6 --activate --email admin@example.com --password '…'
```

`--preset`: `bedrock` | `bedrock-runtime-openai` | `mantle-openai` | `mantle-anthropic` | `openmodel`

등록 후:

1. `GET {gateway}/v1/models` (VK)에 alias가 보이는지 확인  
2. 팀 whitelist를 쓰면 Admin UI → Models → **Team Model Permission**에 추가  
3. Bedrock 신모델이면 Terraform `bedrock_allowed_model_arns`(inference profile + foundation-model)도 확인  

상세 필드·API는 [`guides/admin-guide.md`](guides/admin-guide.md) §4 참고.

### 체크리스트

- [ ] Cognito에 `Claude_<팀>` 그룹 생성  
- [ ] 사용자(및 Admin)를 해당 그룹에 추가  
- [ ] `gateway-cli login` 또는 Cognito 동기화로 DB에 팀 출현  
- [ ] Admin UI에서 팀 예산 활성화 (미설정 = 429)  
- [ ] (권장) 허용 모델 / Rate Limit 설정  

### prod 참고 값

| 항목 | 값 |
|------|-----|
| User Pool | `ap-northeast-2_xa33nFlY3` |
| 기존 팀 예 | `Claude_AWS_Users` → 부서 `AWS` / 팀 `Users` |
| Admin 그룹 | `ClaudeAdmin` (팀 아님) |

최신 엔드포인트·운영 메모는 [`installer.md`](installer.md)를 확인하세요.




---

## 사용자 추가 및 팀 변경 방법

사용자는 Admin UI에서 직접 만들지 않습니다.  
**Cognito에 사용자를 만들고 그룹에 넣은 뒤**, 사용자가 `gateway-cli login` 하거나 Admin이 **Cognito 동기화**하면 DB에 반영됩니다.

빠른 추가:

```bash
./add_user.sh user@example.com                      # 기본 팀 Claude_AWS_Users
./add_user.sh user@example.com --team Claude_AWS_Users --admin
./add_user.sh user@example.com --existing           # 기존 사용자에 그룹만
./add_user.sh --list-groups
```

### 전체 흐름 (신규 사용자)

```
[Admin] Cognito 사용자 생성 + Claude_<팀> 그룹 배정
          ↓
[Admin] 이메일·임시비번·온보딩 안내 전달
          ↓
[사용자] gateway-cli login → 첫 exchange / API
          ↓
[시스템] auth.users + 팀 매핑 자동 생성
          ↓
[Admin] 팀 예산이 꺼져 있으면 Budgets에서 활성화 (미설정 = 429)
          ↓
[사용자] 정상 사용
```

공통 환경:

```bash
export AWS_REGION=ap-northeast-2 AWS_DEFAULT_REGION=ap-northeast-2
USER_POOL_ID="ap-northeast-2_xa33nFlY3"   # prod 예 — terraform output 확인
EMAIL="newuser@company.com"
TEAM_GROUP="Claude_AWS_Users"             # 대상 팀 Cognito 그룹
```

### 1) 사용자 추가 (Cognito)

```bash
TEMP_PASSWORD='Temp_Pass-1234!'   # 12자 이상, 대소문자+숫자 등 풀 정책 준수

aws cognito-idp admin-create-user \
  --user-pool-id "$USER_POOL_ID" \
  --username "$EMAIL" \
  --user-attributes Name=email,Value="$EMAIL" Name=email_verified,Value=true \
  --temporary-password "$TEMP_PASSWORD"

# 팀 그룹 (필수 — 없으면 VK 403 no_matching_team_group)
aws cognito-idp admin-add-user-to-group \
  --user-pool-id "$USER_POOL_ID" \
  --username "$EMAIL" \
  --group-name "$TEAM_GROUP"

# Admin 권한이 필요하면 추가 (팀 그룹과 별개)
# aws cognito-idp admin-add-user-to-group \
#   --user-pool-id "$USER_POOL_ID" \
#   --username "$EMAIL" \
#   --group-name ClaudeAdmin
```

확인:

```bash
aws cognito-idp admin-get-user \
  --user-pool-id "$USER_POOL_ID" --username "$EMAIL" \
  --query 'UserStatus'

aws cognito-idp admin-list-groups-for-user \
  --user-pool-id "$USER_POOL_ID" --username "$EMAIL" \
  --query 'Groups[].GroupName' --output table
```

### 2) 사용자에게 전달할 정보

| 항목 | 내용 |
|------|------|
| 이메일 | Cognito username과 동일 |
| 임시 비밀번호 | 첫 로그인 시 변경 |
| OIDC (gateway-cli) | `OIDC_ISSUER_URL`, `OIDC_CLIENT_ID`, `ADMIN_API_URL`, `ANTHROPIC_BASE_URL` — [`installer.md`](installer.md) / README |
| 시작 가이드 | [`guides/user-guide.md`](guides/user-guide.md), [`guides/QUICKSTART.md`](guides/QUICKSTART.md) |

```bash
export OIDC_ISSUER_URL="https://cognito-idp.ap-northeast-2.amazonaws.com/${USER_POOL_ID}"
export OIDC_CLIENT_ID="l5b47iln436rs5ejdcvo17gt7"   # prod 예
# ADMIN_API_URL / ANTHROPIC_BASE_URL 은 installer.md 엔드포인트 표 참고
gateway-cli login
```

첫 로그인 후 Cognito `UserStatus`가 `CONFIRMED`인지 확인합니다.

### 3) DB 반영 (둘 중 하나)

1. **사용자** `gateway-cli login` — `auth.users` INSERT + 팀 매핑  
2. **Admin UI** → Users → **Cognito 동기화** (이미 ADMIN 세션이 있을 때)

동기화로 바뀌는 것 예: `users_created` / `users_updated` / `users_deactivated` / `teams_deleted`

> Admin UI는 사용자를 자동 생성하지 않습니다. 첫 프로비저닝은 보통 `gateway-cli login` → exchange입니다.

### 4) 팀 변경 (기존 사용자)

Cognito에서 **이전 팀 그룹 제거 → 새 팀 그룹 추가**합니다. Admin UI에서 팀 드롭다운만 바꿔서는 IdP와 어긋납니다.

```bash
EMAIL="user@company.com"
OLD_GROUP="Claude_OldTeam"
NEW_GROUP="Claude_NewTeam"

aws cognito-idp admin-remove-user-from-group \
  --user-pool-id "$USER_POOL_ID" \
  --username "$EMAIL" \
  --group-name "$OLD_GROUP"

aws cognito-idp admin-add-user-to-group \
  --user-pool-id "$USER_POOL_ID" \
  --username "$EMAIL" \
  --group-name "$NEW_GROUP"
```

이후 반영 시점:

| 경로 | 언제 |
|------|------|
| 사용자 재로그인 / 토큰 갱신 (~1시간) | DB 팀 매핑 변경, 기존 VK 무효화, 이전 팀 Budget/RL에서 제외 |
| Admin UI Cognito 동기화 | 관리자가 즉시 일괄 upsert |

새 팀 예산이 $0 HARD_BLOCK이면 이동 후에도 **429**일 수 있습니다 → Budgets에서 활성화.

여러 `Claude_*` 그룹에 동시에 속하면 매핑 규칙에 따라 해석됩니다. 운영에서는 **팀 그룹은 하나만** 두는 것을 권장합니다.

### 5) 사용자 비활성 (참고)

```bash
aws cognito-idp admin-disable-user \
  --user-pool-id "$USER_POOL_ID" \
  --username "$EMAIL"
```

이후 Cognito 동기화 시 `users_deactivated`로 반영될 수 있습니다. 상세는 [`guides/admin-guide.md`](guides/admin-guide.md)를 보세요.

### 체크리스트

- [ ] Cognito 사용자 생성 + `Claude_<팀>` 그룹 배정  
- [ ] (Admin이면) `ClaudeAdmin` + 팀 그룹 둘 다  
- [ ] 안내 메일/메시지 전달 → 사용자 `gateway-cli login`  
- [ ] DB에 사용자·팀 매핑 확인 (또는 Cognito 동기화)  
- [ ] 팀 예산 활성 여부 확인 (미설정 = 429)  
- [ ] 팀 변경 시 old 그룹 remove + new 그룹 add + 재로그인/동기화  

---

## API Key (Virtual Key) 발급

게이트웨이 추론 인증은 **Virtual Key(VK)** 입니다. LiteLLM처럼 Admin이 마스터키로 유저 id/key를 나눠 주는 방식이 **아닙니다.**  
키 형태는 `vk-…` 이고, 요청 시 `Authorization: Bearer <vk-…>` + 게이트웨이 Base URL(`ANTHROPIC_BASE_URL`)을 씁니다. 별도 user id 헤더는 없습니다.

상세는 [`guides/admin-guide.md`](guides/admin-guide.md) §7, 사용자 쪽은 [`manual_users.md`](manual_users.md) / [`guides/QUICKSTART.md`](guides/QUICKSTART.md)를 참고하세요.

### 원칙

| 무엇 | 누가 / 어디서 | 비고 |
|------|----------------|------|
| VK 발급 | **사용자** `gateway-cli login` (또는 OIDC id_token → `/v1/auth/exchange`) | Admin UI에 “키 발급” 버튼 없음 |
| 신원·팀 귀속 | Cognito 그룹 → exchange 시 DB 사용자/팀에 묶임 | `Claude_*` 팀 그룹 필수 |
| 목록·폐기 | **Admin UI → API Keys** | prefix만 표시 (`vk-` + 앞 8자) |
| 사용 | 클라이언트 / HTTP | `Bearer vk-…` + `ANTHROPIC_BASE_URL` |

- **1인 1키**: 새 VK 발급 시 이전 ACTIVE 키는 자동 만료  
- **TTL**: `OIDC_VK_TTL_HOURS` 기본 **1시간** — 만료 전후 `gateway-cli`가 재발급하거나 사용자가 재로그인  
- 팀 예산 미설정이면 키는 있어도 추론은 **429**

### 전제 (발급 전에 Admin이 확인할 것)

- [ ] Cognito에 사용자 + `Claude_<팀>` 그룹 배정 ([사용자 추가](#사용자-추가-및-팀-변경-방법))  
- [ ] 팀 예산 Admin UI에서 활성 ([팀 추가](#팀-추가) §4)  
- [ ] 사용자에게 `OIDC_ISSUER_URL`, `OIDC_CLIENT_ID`, `ADMIN_API_URL`, `ANTHROPIC_BASE_URL` 안내  

### 1) 사용자 발급 (권장)

```bash
export OIDC_ISSUER_URL="https://cognito-idp.ap-northeast-2.amazonaws.com/ap-northeast-2_xa33nFlY3"
export OIDC_CLIENT_ID="l5b47iln436rs5ejdcvo17gt7"   # prod 예
export ADMIN_API_URL="…"      # installer.md 엔드포인트
export ANTHROPIC_BASE_URL="…" # 게이트웨이(추론) ALB

gateway-cli login --issuer-url "$OIDC_ISSUER_URL" --client-id "$OIDC_CLIENT_ID"
# → 브라우저 Cognito 로그인 → VK가 로컬에 캐시됨

# Claude Code 연동 예
gateway-cli setup --gateway-url "$ANTHROPIC_BASE_URL" --admin-api-url "$ADMIN_API_URL"
gateway-cli status
```

사용자 온보딩 스크립트: `scripts/onboard-macos-linux.sh` / `scripts/onboard-windows.ps1`.

### 2) 수동 exchange (스크립트·디버그)

`gateway-cli login` 후 캐시된 **id_token**으로 admin-api에서 VK를 받을 수 있습니다.

```bash
# ~/.gateway-cli/oidc-tokens.json 의 id_token 사용 (권한 0600)
python3 - <<'PY'
import json, os, urllib.request
tok = json.load(open(os.path.expanduser("~/.gateway-cli/oidc-tokens.json")))["id_token"]
req = urllib.request.Request(
    os.environ["ADMIN_API_URL"].rstrip("/") + "/v1/auth/exchange",
    data=b"{}",
    headers={"Authorization": "Bearer " + tok, "Content-Type": "application/json"},
    method="POST",
)
print(json.load(urllib.request.urlopen(req))["virtual_key"])
PY
```

응답의 `virtual_key`를 클라이언트에 넣습니다. **평문 키는 한 번만 보이거나 로컬 캐시에만 두세요.** Admin UI에는 전문이 안 나옵니다.

### 3) HTTP로 추론 (URL + Key)

```bash
curl -sS "$ANTHROPIC_BASE_URL/v1/messages" \
  -H "Authorization: Bearer ${VIRTUAL_KEY}" \
  -H "Content-Type: application/json" \
  -H "anthropic-version: 2023-06-01" \
  -d '{"model":"<허용된-모델명>","max_tokens":64,"messages":[{"role":"user","content":"ping"}]}'
```

agentic-work(LiteLLM)의 `llm_gateway_url` + `llm_gateway_key`와 역할은 비슷하지만, 키는 Cognito 로그인으로 받은 **단기 `vk-`** 입니다.

### 4) Admin: 목록 · 폐기 · 강제 재인증

**목록**

1. Admin UI → **API Keys**  
2. Status (`ACTIVE` / `EXPIRED` / `REVOKED`), Team / User / Email 필터  
3. 표시: Key Prefix, User, Status, Issued / Expires / Last Used  

**즉시 폐기 (Revoke)**

1. API Keys → 해당 키 → **Revoke**  
2. Redis/캐시에서 즉시 무효 → 다음 요청 **401**  
3. 사용자는 `gateway-cli login`으로 새 VK 재발급  

**팀 전체 강제 재인증**

1. Admin UI → Users → 팀 → **Force Reauth**  
2. 해당 팀 ACTIVE VK 전부 REVOKE → 전원 재로그인 필요 (유출·정책 변경 시)

### 자주 겪는 문제

| 증상 | 원인 / 조치 |
|------|-------------|
| `403 no_matching_team_group` | Cognito에 `Claude_*` 팀 그룹 없음 → 그룹 배정 후 재로그인 |
| `401` / Invalid token | VK 만료·Revoke·잘못된 Bearer → `gateway-cli login` |
| `429` | 팀 예산 $0 HARD_BLOCK 또는 소진 → Budgets 활성화 |
| Admin UI에서 키 문자열을 복사하고 싶음 | 불가(마스킹). 사용자가 CLI로 재발급 |
| Admin이 대신 장기 키 발급 | 지원하지 않음. 설계상 OIDC → 단기 VK |

### 체크리스트

- [ ] 사용자·팀·예산 준비 완료  
- [ ] 사용자 `gateway-cli login` 성공 → VK 캐시  
- [ ] (선택) `gateway-cli setup` 또는 HTTP Bearer로 추론 확인  
- [ ] Admin UI API Keys에서 ACTIVE / prefix 확인  
- [ ] 사고 시 Revoke 또는 Force Reauth  

