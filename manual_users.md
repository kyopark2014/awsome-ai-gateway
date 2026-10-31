# 사용자 접속 가이드

일반 사용자는 **Admin UI가 아니라** `gateway-cli`로 Cognito 로그인 → Virtual Key 발급 → Claude Code / Codex / Cowork 로 게이트웨이를 씁니다.

운영자(계정 발급) 절차는 [`mannual_admin.md`](mannual_admin.md) · [`add_user.sh`](add_user.sh)를 참고하세요.

---

## 접속 URL 정리 (헷갈리기 쉬운 것)

| 주소 | 용도 | 직접 브라우저로 여나? |
|------|------|----------------------|
| Cognito Hosted UI (authorize URL) | 로그인 화면 | **아니요** — `gateway-cli login`이 엽니다 |
| `http://localhost:8090/callback` | CLI가 code를 받는 임시 주소 | **절대 직접 열지 마세요** |
| Admin UI `http://localhost:3000` | 관리자 전용 | 일반 사용자 불필요 |
| `ADMIN_API_URL` / `ANTHROPIC_BASE_URL` | API·게이트웨이 | 브라우저 “홈페이지”가 아님 |

접속의 시작점은 항상 터미널의 `gateway-cli login`입니다.

---

## 접속 전에 받을 것

운영자에게 아래를 받으세요.

| 항목 | 설명 |
|------|------|
| 이메일 | Cognito 계정 (보통 회사/개인 메일) |
| 임시 비밀번호 **또는** 영구 비밀번호 | 첫 로그인은 임시 비번 → 새 비번 설정. 운영자가 영구 비번을 넣어 준 경우 그것으로 로그인 |
| `OIDC_ISSUER_URL` | Cognito issuer |
| `OIDC_CLIENT_ID` | OIDC public client |
| `ADMIN_API_URL` | Virtual Key 발급 API |
| `ANTHROPIC_BASE_URL` | 추론 게이트웨이 |

prod 예 (운영자가 안내한 값으로 덮어쓰세요):

```bash
export OIDC_ISSUER_URL="https://cognito-idp.ap-northeast-2.amazonaws.com/ap-northeast-2_xa33nFlY3"
export OIDC_CLIENT_ID="l5b47iln436rs5ejdcvo17gt7"
export ADMIN_API_URL="http://k8s-llmgatew-llmgatew-4e06a94bc4-1287247182.ap-northeast-2.elb.amazonaws.com"
export ANTHROPIC_BASE_URL="https://llm.my-agentic-ai.click"
```

셸 프로파일(`~/.zshrc` 등)에 넣어 두면 편합니다.

### Cognito 비밀번호 정책 (prod)

| 규칙 | 값 |
|------|-----|
| 최소 길이 | **12자** |
| 대문자 / 소문자 / 숫자 | 필수 |
| 특수문자 | 필수는 아님 |

10자 비밀번호(`Wifi1234!!` 등)는 `Password not long enough` 로 거절됩니다.

---

## 한 번에 하기 (권장 · macOS / Linux)

저장소가 있고 `uv`가 있으면 온보딩 스크립트가 CLI 설치 + 로그인까지 합니다.

```bash
cd /path/to/awsome-ai-gateway   # 또는 gateway-cli 가 있는 경로

# 위 4개 export 후
bash scripts/onboard-macos-linux.sh

# Claude Code 연동까지:
bash scripts/onboard-macos-linux.sh --setup-claude-code
```

Windows는 `./scripts/onboard-windows.ps1` (필요 시 `-SetupClaudeCode`).

---

## 수동 접속 순서

### 1) gateway-cli 설치

**uv (권장)** — 저장소 루트에서:

```bash
uv tool install --from ./gateway-cli gateway-cli
gateway-cli version
```

또는 운영자가 준 바이너리 패키지를 `PATH`에 넣습니다.

### 2) Cognito 로그인

```bash
gateway-cli login \
  --issuer-url "$OIDC_ISSUER_URL" \
  --client-id "$OIDC_CLIENT_ID"
```

또는 env만 맞춰 두고:

```bash
gateway-cli login
```

진행 순서:

1. 터미널에 `Opening browser for OIDC login...` 와 Cognito URL이 출력됩니다.  
2. **이 상태에서** 브라우저가 열린 Cognito에서 이메일·비밀번호로 로그인합니다.  
3. Cognito가 `http://localhost:8090/callback?code=...&state=...` 로 리다이렉트합니다 — **CLI가 자동으로 받습니다.**  
4. 성공 메시지 예: `Login successful.` (또는 `Login complete`)  
5. 토큰: `~/.gateway-cli/oidc-tokens.json` (mode 0600)

중요:

- callback URL을 주소창에 **복사·붙여넣기하지 마세요.** CLI가 꺼진 뒤에는 8090에 서버가 없어 “접속할 수 없음”이 납니다. **정상**입니다.  
- 로그인 대기 시간은 기본 **300초(5분)** 입니다. 초과 시 `Login failed: login timed out after 300s` → 처음부터 `gateway-cli login` 재실행.  
- `redirect port 8090 is busy` → 다른 앱이 8090을 쓰거나 이전 login이 남아 있음. 끄거나 `--redirect-port 8091` 사용.  
- 첫 계정이 `FORCE_CHANGE_PASSWORD`이면 임시 비번으로 들어가 **새 비밀번호를 설정**해야 합니다. Hosted UI “비밀번호 찾기”는 이 상태에서 메일이 안 오는 경우가 많습니다 → [비밀번호·메일](#비밀번호와-재설정-메일) 참고.

이후 Virtual Key 발급·갱신은 `api-key-helper`가 자동으로 합니다. 평소에는 재로그인이 필요 없습니다.

### 3) 클라이언트 연결

#### Claude Code

```bash
# 미설치 시
npm install -g @anthropic-ai/claude-code

gateway-cli setup \
  --gateway-url "$ANTHROPIC_BASE_URL" \
  --admin-api-url "$ADMIN_API_URL" \
  --issuer-url "$OIDC_ISSUER_URL" \
  --client-id "$OIDC_CLIENT_ID"

claude
```

`gateway-cli setup` 중 `Password:` 가 뜨면:

- **Mac/Linux 관리자(sudo) 비밀번호**입니다. Cognito 비밀번호가 아닙니다.  
- `/etc/claude-code/managed-settings.d/` 에 설정 파일을 쓰려고 sudo를 쓰기 때문입니다.  
- Cognito 비번을 넣으면 `Sorry, try again.` 이 납니다.

원복: `gateway-cli disable`

#### Codex / Cowork

클라이언트별 설정은 [`guides/QUICKSTART.md`](guides/QUICKSTART.md) §2-B / §2-C, [`docs/guides/connect.md`](docs/guides/connect.md)를 따릅니다.  
Cowork은 HTTPS BASE URL이 필요할 수 있습니다 (현재 prod ALB가 HTTP면 운영자 안내를 확인하세요).

### 4) 상태 확인

```bash
gateway-cli status
gateway-cli logout    # 필요 시
```

---

## 비밀번호와 재설정 메일

조사·운영에서 확인된 내용입니다.

### 왜 “비밀번호 찾기” 메일이 안 오나?

1. **계정이 `FORCE_CHANGE_PASSWORD`(임시 비번) 상태**이면 Cognito 로그인 화면의 재설정이 사실상 동작하지 않습니다.  
   - `AdminResetUserPassword`도 `User password cannot be reset in the current state` 로 거절됩니다.  
   - `ForgotPassword` API가 `CodeDeliveryDetails`를 돌려줘도 **메일이 실제로 가지 않거나 쓸 수 없는 경우**가 있습니다.  
2. `email_verified=true` 로 바꿔도, 위 상태가 유지되면 재설정 메일은 기대하지 마세요.  
3. 풀 이메일은 Cognito 기본 발송(`COGNITO_DEFAULT`)이라 SES 전용 도메인이 없고, 스팸함·일일 한도 이슈도 있습니다.  
4. `add_user.sh`는 `--message-action SUPPRESS` 로 만들어 **초대(임시 비번) 메일 자체를 보내지 않습니다.** 터미널에 출력된 임시 비번을 쓰세요.

### 사용자가 할 일

- 임시 비번을 알고 있으면: `gateway-cli login` → Cognito에서 로그인 → **새 비밀번호 설정**(12자 이상).  
- 임시 비번을 모르면: 운영자에게 **영구 비밀번호 설정**을 요청하세요. “메일로 재설정”은 이 상태에서 보통 불가합니다.

### 운영자가 할 일 (영구 비번 설정)

```bash
aws cognito-idp admin-set-user-password \
  --user-pool-id ap-northeast-2_xa33nFlY3 \
  --username user@example.com \
  --password '12자이상_대소문자숫자포함' \
  --permanent

# 권장
aws cognito-idp admin-update-user-attributes \
  --user-pool-id ap-northeast-2_xa33nFlY3 \
  --username user@example.com \
  --user-attributes Name=email_verified,Value=true
```

이후 `UserStatus`가 `CONFIRMED`가 되면 그 비밀번호로 `gateway-cli login` 하면 됩니다.  
재설정을 여러 번 시도하면 `LimitExceededException`(시도 한도)이 날 수 있어 잠시 후 재시도하세요.

---

## Agent에서 API Key 사용

agentic-work 등 **URL + Key** 로 LLM을 붙이는 Agent/앱에서 AWSome AI Gateway를 쓸 때입니다.  
(Claude Code는 위 `gateway-cli setup` 경로를 쓰고, 여기는 LiteLLM형 설정 모달·SDK 기준입니다.)

### 넣을 값

| 필드 | 값 | 비고 |
|------|-----|------|
| **URL** | 게이트웨이 Base URL (`ANTHROPIC_BASE_URL`) | **추론 ALB**. admin-api URL 아님 |
| **Key** | Virtual Key (`vk-…`) | Cognito 로그인 사용자 명의로 발급. 플레이스홀더가 `sk-…`여도 `vk-…` 사용 |

앱은 보통 `GET {URL}/v1/models` 에 `Authorization: Bearer {Key}` 로 모델 목록을 확인한 뒤 저장합니다. 게이트웨이는 이 경로를 지원합니다.

prod 예 (`config.json`의 `anthropic_base_url`과 동일 — 운영자 안내값으로 덮어쓰세요):

```text
URL:  https://llm.my-agentic-ai.click
Key:  vk-…   (본인 계정으로 발급)
```

### Key 발급 (본인 계정)

운영자가 Cognito 계정·팀 그룹을 만들어 둔 뒤:

```bash
# 저장소 루트에서 (config.json 사용)
# 1) gateway-cli login 으로 id_token 확보 후, 또는 --password / --set-password
./add_apiKey.sh you@example.com --out /tmp/my-vk.txt
cat /tmp/my-vk.txt
```

- **1인 1키**: 다시 발급하면 이전 ACTIVE 키는 만료될 수 있습니다.  
- **TTL**: 기본 약 1시간 (`OIDC_VK_TTL_HOURS`) — 만료되면 위 명령을 다시 실행하거나 `gateway-cli login` 후 재발급하세요.  
- Admin UI API Keys에는 키 **전문이 안 보입니다** (prefix만).

### Agent 설정 예 (agentic-work)

사이드바 **LLM Gateway** 모달:

1. **URL**에 게이트웨이 Base URL 입력  
2. **Key**에 `vk-…` 입력 (변경할 때만; 비우면 기존 키 유지인 UI도 있음)  
3. **확인** — 모델 목록 조회 성공 시 저장·활성화  

별도 user id 필드는 없습니다. 신원은 Virtual Key에 묶입니다.

### 주의

| 이슈 | 설명 |
|------|------|
| admin-api URL을 넣음 | `/v1/models`·추론이 실패합니다. 반드시 **게이트웨이** URL |
| HTTP ALB만 있음 | Agent가 다른 VPC/인터넷에 있으면 연결이 안 될 수 있습니다. HTTPS·공개 엔드포인트는 운영자에게 문의 |
| 429 | 팀 예산 미설정·소진 — 운영자 Admin UI Budgets |
| 401 | VK 만료·폐기 — `add_apiKey.sh` / `gateway-cli login` 재발급 |
| 403 `no_matching_team_group` | Cognito `Claude_*` 팀 그룹 없음 — 운영자에게 그룹 배정 |

관리자 절차(팀·사용자·키): [`mannual_admin.md`](mannual_admin.md), 스크립트: `add_team.sh` / `add_user.sh` / `add_apiKey.sh` + `config.json`.

---

## 자주 겪는 문제

| 증상 | 원인 / 조치 |
|------|-------------|
| `Missing required OIDC config` | `OIDC_ISSUER_URL` / `OIDC_CLIENT_ID` export 또는 `--issuer-url` / `--client-id` |
| `http://localhost:8090/callback` 접속 불가 | **정상.** CLI login 종료 후에는 서버가 없음. URL을 직접 열지 말 것 |
| `Login failed: login timed out after 300s` | 5분 안에 Cognito 로그인을 끝내지 못함 → `gateway-cli login` 재실행 |
| `redirect port 8090 is busy` | 포트 충돌 → 프로세스 종료 또는 `--redirect-port 8091` |
| setup 중 `Password:` / `Sorry, try again` | **sudo(Mac 로그인 비번)** 필요. Cognito 비번 아님 |
| `Password not long enough` | 최소 **12자** |
| 비밀번호 찾기 메일 없음 | `FORCE_CHANGE_PASSWORD`면 재설정 메일 불가 → 운영자 `admin-set-user-password --permanent` |
| 403 `no_matching_team_group` | Cognito에 `Claude_*` 팀 그룹 없음 → 운영자에게 그룹 배정 |
| 429 / budget | 팀 예산 미설정·소진 → 운영자 Admin UI Budgets |
| `Login successful` 인데 callback을 또 염 | 이미 완료. `gateway-cli setup` → `claude` 로 진행 |
| Agent LLM Gateway 모델 확인 실패 | URL이 admin-api인지·VK 만료·네트워크(HTTP ALB) 확인 → [Agent에서 API Key 사용](#agent에서-api-key-사용) |

---

## Admin UI는?

일반 사용자용 화면이 아닙니다. 관리자(예산·동기화 등)만 씁니다.  
HTTPS 전에는 port-forward + http://localhost:3000/api/auth/login — [`mannual_admin.md`](mannual_admin.md) / [`installer.md`](installer.md).  
Admin UI callback(`http://localhost:3000/api/auth/callback`)도 직접 열면 state 쿠키 오류가 납니다. `/api/auth/login`부터 시작하세요.

---

## 체크리스트

- [ ] 운영자에게 계정·비밀번호·4개 URL/ID 수령  
- [ ] `gateway-cli` 설치  
- [ ] `gateway-cli login` 성공 (`Login successful`) — callback URL은 직접 열지 않음  
- [ ] (Claude Code) `gateway-cli setup` 시 **Mac sudo 비밀번호** 입력  
- [ ] `claude` 실행  
- [ ] (Agent) 게이트웨이 URL + `add_apiKey.sh`로 받은 `vk-…` 설정  
- [ ] 429면 운영자에게 팀 예산 활성화 요청  

상세: [`guides/QUICKSTART.md`](guides/QUICKSTART.md), [`guides/user-guide.md`](guides/user-guide.md).
