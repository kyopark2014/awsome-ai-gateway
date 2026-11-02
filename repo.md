# AWSome AI Gateway 프로젝트 상세 설명

> 이 문서는 repo 전체(약 1,320개 추적 파일)를 훑어 정리한 개요입니다. 세부 사항은 각 절에 링크한 원본 문서(`README.md`, `ARCHITECTURE.md`, `guides/`, `deployment/docs/`)를 기준으로 하세요.

---

## 1. 한 줄 요약

**사내 코딩 에이전트(Claude Code / Codex / Cowork)를 위한 통합 LLM 게이트웨이.**
OIDC(Cognito) 로그인으로 Virtual Key(VK)를 자동 발급하고, 요청을 client·모델에 맞는 AWS Bedrock 백엔드/계정으로 프록시하면서 **예산·Rate Limit·모델 접근 제어·사용량 추적·서버사이드 웹서치**를 한 곳에서 처리합니다. 운영자는 관리 콘솔(Admin UI)과 자연어 BI 어시스턴트(`admin-chat-agent`)로 운영 데이터를 봅니다.

이 repo는 [aws-samples/sample-agentic-ai-acceleration-kr 의 awsome-ai-gateway](https://github.com/aws-samples/sample-agentic-ai-acceleration-kr/tree/main/projects/awsome-ai-gateway)를 **포크**한 것이며, 이 포크의 목적은 **배포(deploy) 관련 설정을 자체 환경(prod, ap-northeast-2, EKS Fargate)에 맞게 갱신**하는 것입니다.

---

## 2. 아키텍처 개요

두 개의 plane으로 분리됩니다.

| Plane | 구성 | 특성 |
|---|---|---|
| **Data plane** | `gateway-proxy` → Bedrock (native / Mantle / bedrock-runtime) | 지연 민감, 고 QPS |
| **Control plane** | `admin-ui` → `admin-api` → Aurora, AgentCore Runtime(BI) | 사람 대상, 저 QPS |

```
Claude Code / Codex / Cowork
   │  gateway-cli(api-key-helper): OIDC id_token → VK 발급
   ▼
admin-api  (/v1/auth/exchange: JWKS 검증 + 사용자 프로비저닝 → VK)
   │
클라이언트 ──Bearer VK──▶ gateway-proxy
   미들웨어: OTel → ClientId → Auth → ClientAuthZ → Budget → Downgrade → RateLimit → ...
   라우팅: model.routing_profiles (DB row, Redis TTL 300s 캐시)
        ├ claude-code → Bedrock NATIVE (boto3 invoke_model), STS AssumeRole
        ├ codex       → Bedrock Mantle(기본) / bedrock-runtime OpenAI 호환 (us-east-2)
        └ cowork      → Bedrock Mantle (Anthropic Messages, 도쿄)
   cost finalize ─XADD→ Redis Stream(cost:stream)
                              ▼
        cost-recorder-worker → Aurora(usage_logs, budget_usages)
        notification-worker  → 이메일(SES/SMTP/mock)
        scheduler            → ROI 집계, VK 만료 정리
```

핵심 설계 포인트
- **데이터 드리븐 라우팅**: 백엔드 분기는 코드가 아니라 `routing_profiles` 테이블 row. 미등록/disabled client는 기본 Bedrock 경로로 폴백.
- **멀티계정**: 모델(alias)별/앱(client)별로 다른 AWS 계정으로 STS AssumeRole(+ExternalId). 실패 시 게이트웨이 계정으로 투명 폴백(claude-code), alias 계정 전환 실패 시에는 500.
- **Re-origination 보안**: 요청을 그대로 relay하지 않고 게이트웨이가 새로 구성해 업스트림에 보냄(자격증명 누수 구조적 방지).
- **모델 허용 목록은 DB 주도**: `model.model_aliases`에 행을 추가(마이그레이션 또는 Admin UI/`add_model.sh`)해서 신모델을 개방. Helm의 `BEDROCK_ALLOWED_MODELS`는 읽는 코드가 없는 dead config.
- **서버사이드 웹서치**: routing profile의 `web_search_enabled=True`일 때 게이트웨이가 `web_search` 툴을 주입→tool_use 인터셉트→AgentCore Gateway(MCP, SigV4/IRSA)로 호출→결과 재투입. 클라이언트 무설정. 글로벌 kill-switch 기본 off.
- **AI BI 어시스턴트**: Strands 기반 multi-agent(Orchestrator/SQL/Code/Viz/Report/Validator)가 Bedrock AgentCore Runtime에서 실행, read-only DB role로 Aurora 질의, SSE 스트리밍.

---

## 3. 디렉터리 / 파일 종류별 설명

### 3.1 서비스(애플리케이션 코드)

| 경로 | 언어/스택 | 역할 |
|---|---|---|
| `gateway-proxy/` (232 files) | Python, FastAPI | **데이터 플레인**. VK 인증, client 식별, 예산/RateLimit(Redis Lua), 모델 다운그레이드, provider 어댑터, SSE 스트리밍, 웹서치 루프, cost 스트림 발행 |
| `admin-api/` (199) | Python, FastAPI, SQLAlchemy, uv | **컨트롤 플레인 API**. OIDC→VK 교환, 모델/팀/예산/Rate Limit CRUD, 대시보드·분석·모니터링, 감사(invocation log), BI 챗 프록시, AWS 계정 레지스트리, 가격표 동기화 |
| `admin-ui/` (207) | Next.js 14, React 18, TypeScript, Tailwind, Playwright/Vitest | 관리 콘솔. 페이지: `models`, `keys`, `budgets`, `rate-limits`, `users`, `apps`, `monitoring`, `chat`, `my`. i18n(ko/en) |
| `admin-chat-agent/` (72) | Python, Strands, AgentCore | BI 챗 에이전트. `prompts/*.md`(오케스트레이터·SQL·코드·시각화·리포트 등), `fewshot`, `sql_guard`, Lambda(`query_db`, `get_schema`), golden 평가 테스트 |
| `cost-recorder-worker/` (25) | Python | `cost:stream` 소비 → `usage_logs` bulk INSERT, `budget_usages` UPSERT, 일 집계(KST) |
| `notification-worker/` (77) | Python | `notifications:*` pub/sub 구독 → 이메일 발송 (dev/prod 기본 `mock`) |
| `gateway-cli/` (54) | Python | 사용자 CLI. `login`/`setup`/`status`/`disable`, `api_key_helper`(Claude Code가 호출), `statusline`, 도구 설정(Bedrock/OpenAI/OTel) |
| `mock/` | Python | 로컬용 mock vLLM |

### 3.2 데이터베이스 — `db/`

- `init/01~08_*.sql`: 스키마/테이블/시드/DB 사용자(`gateway_chat_reader` 등) 초기화.
- `versions/0001~0045_*.py`: **Alembic 마이그레이션 체인**. 모델 alias 추가(Claude 4.x/5/5.5/Fable, GPT-5.6/6, Llama), 라우팅 프로파일(Mantle/codex/claude-code 크로스계정), 예산·rate limit·system_settings, 장문 컨텍스트 요금, AWS 계정 레지스트리(0044), `usage_logs.aws_account_id`(0045) 등.
- 주요 스키마: `auth`, `model`, `budget`, `usage`, `audit`, `notification`, `chat_agent`(pgvector).

### 3.3 인프라/배포 — `deployment/`

| 경로 | 내용 |
|---|---|
| `charts/llm-gateway/` | Helm chart (6 Deployment + migration Job). `values.yaml`, `values-eks-fargate-{dev,prod,prod-loadtest}.yaml` |
| `terraform/modules/` | `vpc`, `eks-fargate`, `aurora-postgresql`, `elasticache-valkey`, `cognito`, `irsa`, `alb-controller`, `external-secrets`, `agentcore-runtime`, `bedrock-invocation-logging`, `body-logging` |
| `terraform/environments/` | `llm-gateway-dev`, `llm-gateway-prod` |
| `docs/eks-fargate/` | 01~09 단계별 설치 가이드 + troubleshooting |
| `scripts/` | tfstate 부트스트랩, `install-eks.sh`, `deploy-tui.sh`, `smoke-test.sh`, AgentCore 웹서치/Bedrock 로깅/cowork 크로스계정 role provisioning |
| `tui/` | 배포용 Python TUI(preflight → 단계 실행 → postdeploy) |
| `observability/` | kube-prometheus-stack, Grafana, OTel collector, prometheus-adapter 설치 스크립트 |

로컬 개발: 루트 `docker-compose.yml`(postgres, redis, gateway-proxy, admin-api, admin-ui, scheduler, workers, otel/prometheus/loki/tempo/grafana), `docker-compose.idp.yml`(로컬 IdP). 관측 설정은 `config/`.

### 3.4 클라이언트 배포·설치

- `installer/` (Windows `.iss`/PowerShell, Linux `.deb`/PyInstaller): `gateway-cli` 설치 패키지.
- `cowork-installer/`: Cowork용 설치 패키지/가이드.
- `scripts/`: macOS/Linux/Windows 온보딩, cowork Mantle IAM 생성.
- `gateway-clients/`: `claude-box`, `codex-box` 컨테이너 및 `gw.sh`.

### 3.5 운영 헬퍼 스크립트 (루트, 이 포크에서 추가)

| 파일 | 용도 |
|---|---|
| `config.json` | 환경 설정(리전, Cognito User Pool/Client, admin-api URL, gateway base URL, 그룹 규칙) |
| `load_config.sh` | 아래 스크립트들이 source하는 공통 로더. 이미 export된 env가 있으면 config보다 우선 |
| `add_user.sh` | Cognito 사용자 생성 + `Claude_*` 팀 그룹/`--admin` 추가 |
| `add_team.sh` | Cognito 그룹(`Claude_<팀>`) 생성 |
| `add_apiKey.sh` | Admin API로 API Key(VK) 발급 |
| `add_model.sh` | `POST /admin/models`로 모델 alias 등록/조회/활성·비활성 (preset: bedrock, bedrock-runtime-openai 등) |

### 3.6 문서

| 파일 | 내용 |
|---|---|
| `README.md` / `README.en.md` | 프로젝트 소개, 아키텍처, 지원 모델, 차별점, SSE 타임아웃 |
| `ARCHITECTURE.md` | as-built 상세(컴포넌트, 데이터 스토어, 인증, 데이터 플로우) |
| `installer.md` | **이 포크의 prod 배포 기록**(엔드포인트, Cognito, 진행 상태) |
| `manual_users.md` | 일반 사용자 접속 가이드(`gateway-cli login` → VK → 도구 사용) |
| `mannual_admin.md` | 운영자 매뉴얼(팀 추가, 사용자 추가, 모델 등록 등) |
| `guides/` | `QUICKSTART`, `admin-guide`, `user-guide`, `deployer-guide`, `small_scale_guide` |
| `docs/` | 아키텍처 drawio·PNG, 멀티계정 설정, IRSA, Cowork vs Claude Code, 블로그 초안 |
| `AWSome-AI-Gateway-Deck.md` | 발표 자료용 덱 |

---

## 4. 주요 동작 상세

### 인증
1. 사용자: `gateway-cli login` → Cognito Hosted UI(로컬 `localhost:8090/callback`) → `id_token`.
2. `api-key-helper`가 `POST /v1/auth/exchange`(Bearer id_token) → admin-api가 JWKS 검증 → VK 반환. (access_token이 아닌 id_token을 쓰는 이유: Cognito access_token에 email/groups claim이 없음.)
3. 추론 호출은 VK로 인증. 경로별 전략: `/model/*`=VK, `/v1/messages|responses|models|chat/completions`=VK 또는 admin JWT, 그 외 `/v1/*`=JWT.
4. 팀은 **Cognito 그룹**(`Claude_<팀>` 또는 `Claude_<부서>_<팀>`)으로 결정. 매칭 그룹 없으면 `403 no_matching_team_group`. 관리자는 `ClaudeAdmin` 그룹(+팀 그룹 필수).

### 거버넌스
- **예산**: scope USER/TEAM/앱(client)별, 정책 HARD_BLOCK / SOFT_WARNING / THROTTLE. **미설정 시 기본 $0 HARD_BLOCK → 요청이 429**.
- **Rate Limit**: RPM/TPM/CPM/CPH, Redis Lua 토큰 버킷.
- **모델 접근 제어**: 사용자/팀별 allow-list(0행 = 전체 허용), 모델별 allowed clients.
- **다운그레이드**: 예산 임계 시 저렴한 모델로 자동 전환.
- `client` 식별(UA/originator)은 분석·라우팅용이며 **인가 신호가 아님**(스푸핑 가능). 인가는 VK + `allowed_clients`.

### 스트리밍
- `STREAM_IDLE_TIMEOUT`(prod 540s)은 반드시 ALB `idle_timeout`(prod 600s)보다 작아야 함. 초과 시 SSE error 프레임으로 정상 종료하고 그때까지의 토큰은 과금 기록.

### 신모델 추가 시 주의
마이그레이션(또는 `add_model.sh`)만으로는 부족: `global.anthropic.*` inference profile과 foundation-model **양쪽**에 `bedrock:InvokeModel` IAM 허용이 필요(`terraform/.../variables.tf`의 `bedrock_allowed_model_arns`). 누락 시 조용히 AccessDenied. Fable 5/5.1은 계정의 Bedrock 데이터 보존 모드(`aws_review`) 활성화 필요.

---

## 5. 현재 포크의 배포 상태 / 적용점

`installer.md`, `config.json`, 작업 트리 변경 기준:

- **환경**: prod / ap-northeast-2 / EKS Fargate(`llm-gateway-prod`). Aurora PostgreSQL + ElastiCache(Valkey)는 외부 관리형, ESO가 Secrets Manager → K8s Secret 동기.
- **엔드포인트**: Gateway `https://llm.my-agentic-ai.click`(ACM + Route53 alias, HTTPS), Admin API / Admin UI는 아직 HTTP ALB DNS (Cognito 브라우저 SSO는 후속 과제).
- **상태**: 코어 배포 완료 + BI AgentCore Runtime READY + chat_reader 비밀번호 동기화 완료 (`sync-chat-reader-secret.sh`).
- **포크에서 한 변경**
  - `2b92c64`: 운영 스크립트(`add_*.sh`, `load_config.sh`) 추가, prod OIDC VK TTL을 180일로 조정.
  - **미커밋 변경 (현재 working tree)**
    - `values-eks-fargate-prod.yaml`: gateway Ingress를 HTTPS 도메인(`llm.my-agentic-ai.click`)으로 전환(ACM 인증서 어노테이션, 80/443 listen, ssl-redirect). VK TTL을 `adminApi.env.OIDC_VK_TTL_HOURS`에서 `oidc.vkTtlHours: 4320`으로 이동(chart helper가 env로 주입하므로 중복 방지).
    - `manual_users.md`: `ANTHROPIC_BASE_URL`을 ALB DNS → `https://llm.my-agentic-ai.click`로 갱신.
- **이 repo의 사용 흐름**
  1. 인프라: `deployment/terraform` → `deployment/docs/eks-fargate/` 순서 또는 `deployment/scripts/deploy-tui.sh`.
  2. 설치: Helm `values-eks-fargate-prod.yaml`로 `llm-gateway` 차트 배포(migration Job이 Alembic `upgrade head` 선실행).
  3. 운영: `add_team.sh` → `add_user.sh` → Admin UI에서 예산/Rate Limit 설정 → `add_model.sh`로 모델 등록.
  4. 사용자: `manual_users.md` 따라 `gateway-cli login` 후 Claude Code / Codex / Cowork 사용.

### 알아둘 점
- `config.json`, `manual_users.md`, `installer.md`에 실제 환경 값(User Pool ID, Client ID, ALB DNS, 계정 ID)이 들어 있습니다. 비밀번호/시크릿 원문은 없지만, 공개 repo로 올릴 경우 노출 범위를 검토하세요.
- `README.md`, `ARCHITECTURE.md`의 계정 번호/마이그레이션 head(`0022` 표기)는 업스트림 시점 기준이라 일부 오래된 값이 남아 있습니다. 실제 head는 `db/versions`상 **`0045`** 입니다.
- 파일명 `mannual_admin.md`는 오타(manual)지만 다른 문서가 링크하므로 변경 시 링크도 함께 수정해야 합니다.

---

## 6. 테스트

| 영역 | 위치 | 비고 |
|---|---|---|
| admin-api | `admin-api/tests/{unit,integration,regression}` | regression은 `critical/high/medium` 접두사로 중요도 구분, 실DB/Redis 사용 케이스 포함 |
| gateway-proxy | `gateway-proxy/tests/{unit,integration,middleware,regression,services}` | 미들웨어 순서, client id, 라우팅 등 |
| admin-chat-agent | `tests/{unit,eval,golden}` | golden tier A/B 질의 평가, SQL guard |
| admin-ui | `tests/{unit,e2e}` | Vitest, Playwright |
| 기타 | `db/tests`, `deployment/tui/tests`, `deployment/charts/llm-gateway/tests`, `gateway-cli/tests`, worker별 tests | init SQL 가드, Helm 차트 검증 등 |

배포 후 E2E: `deployment/scripts/smoke-test.sh`.

---

## 7. 기술 스택 요약

Python(FastAPI, SQLAlchemy, Alembic, Strands, boto3, httpx, uv) · TypeScript(Next.js 14, React 18, Tailwind) · PostgreSQL(Aurora, pgvector) · Redis/Valkey(Lua, Streams, pub/sub) · AWS(Bedrock, Bedrock Mantle, AgentCore, EKS Fargate, Cognito, ALB, ACM, Route53, Secrets Manager, IRSA, STS, Lambda, S3, CloudWatch) · Helm · Terraform · OpenTelemetry/Prometheus/Grafana/Loki/Tempo · Docker.
