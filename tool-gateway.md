# Tool Gateway — 서버사이드 웹서치 (prod)

Architecture C: `gateway-proxy`가 모델의 `web_search` tool_use를 가로채 **AgentCore Gateway 관리형 WebSearch**(MCP · SigV4/IRSA · **us-west-2**)로 검색한 뒤 결과를 재투입합니다. 클라이언트(Claude Code / Codex / Cowork) 설정은 필요 없습니다.

## 최종 값 (262976740991)

| 항목 | 값 |
|------|-----|
| Region | `us-west-2` (Seoul 배포와 다름) |
| Gateway name | `awsome-ai-gw-websearch` |
| Gateway ID | `awsome-ai-gw-websearch-imy7ac2kbz` |
| MCP URL | `https://awsome-ai-gw-websearch-imy7ac2kbz.gateway.bedrock-agentcore.us-west-2.amazonaws.com/mcp` |
| Target | `web-search-tool` (`IWNOBNSCQG`, READY) |
| Gateway exec role | `arn:aws:iam::262976740991:role/llm-gateway-prod-agentcore-websearch-gw` |
| Caller (IRSA) | `arn:aws:iam::262976740991:role/llm-gateway-prod-gateway-proxy-bedrock` |
| Inbound auth | `AWS_IAM` (SigV4 — Cognito/JWT 아님) |
| 과금 | 관리형 WebSearch ≈ $7 / 1,000 queries (유휴 ≈ $0) |

동일 계정에 agentic-work용 `gateway-websearch`(us-west-2)도 있으나, **본 게이트웨이는 awsome 전용**으로 분리했습니다.

## 이중 스위치

| 스위치 | 위치 | 역할 |
|--------|------|------|
| `WEB_SEARCH_ENABLED` | gateway-proxy env (Helm) | 글로벌 kill-switch |
| `routing_profiles.web_search_enabled` | Aurora `model.routing_profiles` | 클라이언트별 토글 (`claude-code` / `codex` / `cowork`) |

둘 다 true여야 툴이 주입됩니다. URL이 비면 `agentcore_mcp_client`가 None → 웹서치 분기 스킵(무회귀).

prod 현재: 글로벌 on + 세 클라이언트 모두 `web_search_enabled=true` (migration 0021).

## 프로비저닝

스크립트: `deployment/scripts/provision_agentcore_websearch.py` (idempotent).

```bash
cd awsome-ai-gateway
REGION=us-west-2 \
GW_NAME=awsome-ai-gw-websearch \
ROLE_NAME=llm-gateway-prod-agentcore-websearch-gw \
TARGET_NAME=web-search-tool \
CALLER_ROLE_ARN=arn:aws:iam::262976740991:role/llm-gateway-prod-gateway-proxy-bedrock \
python3 deployment/scripts/provision_agentcore_websearch.py deploy

# 상태
REGION=us-west-2 GW_NAME=awsome-ai-gw-websearch \
  python3 deployment/scripts/provision_agentcore_websearch.py status
```

출력의 `AGENTCORE_GATEWAY_URL`을 Helm values에 넣습니다. **이름(`GW_NAME`)을 바꾸면 중복 게이트웨이가 생기므로**, 재실행 시 기존 이름과 values URL을 같이 맞춥니다.

제거(과금·노출 중단):

```bash
REGION=us-west-2 GW_NAME=awsome-ai-gw-websearch ROLE_NAME=llm-gateway-prod-agentcore-websearch-gw \
  python3 deployment/scripts/provision_agentcore_websearch.py teardown
```

## Helm (gateway-proxy)

파일: `deployment/charts/llm-gateway/values-eks-fargate-prod.yaml`

```yaml
global:
  imageRegistry: "262976740991.dkr.ecr.ap-northeast-2.amazonaws.com"  # placeholder 123456789012 금지

gatewayProxy:
  serviceAccount:
    annotations:
      eks.amazonaws.com/role-arn: "arn:aws:iam::262976740991:role/llm-gateway-prod-gateway-proxy-bedrock"
  env:
    AGENTCORE_GATEWAY_URL: "https://awsome-ai-gw-websearch-imy7ac2kbz.gateway.bedrock-agentcore.us-west-2.amazonaws.com/mcp"
    AGENTCORE_REGION: "us-west-2"          # BI Runtime(ap-northeast-2)과 다름
    AGENTCORE_TARGET_ID: "web-search-tool"
    WEB_SEARCH_ENABLED: "true"
```

적용 예:

```bash
helm upgrade llm-gateway deployment/charts/llm-gateway \
  -n llm-gateway \
  -f deployment/charts/llm-gateway/values-eks-fargate-prod.yaml \
  --reuse-values --no-hooks \
  --set global.imageRegistry=262976740991.dkr.ecr.ap-northeast-2.amazonaws.com \
  --set gatewayProxy.env.AGENTCORE_GATEWAY_URL="https://awsome-ai-gw-websearch-imy7ac2kbz.gateway.bedrock-agentcore.us-west-2.amazonaws.com/mcp" \
  --set gatewayProxy.env.AGENTCORE_REGION=us-west-2 \
  --set gatewayProxy.env.AGENTCORE_TARGET_ID=web-search-tool \
  --set gatewayProxy.env.WEB_SEARCH_ENABLED=true
kubectl -n llm-gateway rollout status deploy/llm-gateway-gateway-proxy --timeout=600s
```

주의:

- `--no-hooks`면 Redis ExternalSecret(`llm-gateway-redis`, helm pre-upgrade hook)이 안 만들어집니다. Secret이 없으면 신규 pod가 `CreateContainerConfigError`가 납니다. SM `/llm-gateway/prod/redis` → `password` 동기화(ES `llm-gateway-redis`)를 유지하세요.
- values에 `proxy-xxx` / `xxx.apn2` / ECR `123456789012` placeholder가 남아 있으면 helm `-f` 업그레이드가 라이브 DB·Redis·이미지 경로를 덮어씁니다. prod 확정 값:
  - DB: `llm-gateway-prod.proxy-cv0yiyge2bwv.ap-northeast-2.rds.amazonaws.com`
  - Redis: `clustercfg.llm-gateway-prod.zs7xh6.apn2.cache.amazonaws.com`
  - Registry: `262976740991.dkr.ecr.ap-northeast-2.amazonaws.com`
- `admin-api`의 `AGENTCORE_REGION` / `AGENTCORE_RUNTIME_ARN`은 **BI chat-agent(서울)** 용입니다. gateway-proxy us-west-2 웹서치와 혼동하지 마세요.

## IRSA

Terraform `deployment/terraform/modules/irsa` — `AgentCoreInvokeGateway`:

```text
bedrock-agentcore:InvokeGateway
  on arn:aws:bedrock-agentcore:us-west-2:262976740991:gateway/*
```

게이트웨이 실행 역할(`llm-gateway-prod-agentcore-websearch-gw`)이 `InvokeWebSearch`를 가집니다. 호출자(IRSA)는 InvokeGateway만 있으면 됩니다. 라이브 정책 `llm-gateway-prod-gateway-proxy-bedrock`에 이미 포함되어 있습니다.

## 클라이언트 토글

Admin UI → Routing / Web search, 또는 API:

```http
GET  /admin/routing-profiles
PATCH /admin/routing-profiles/{client}   # web_search_enabled
```

변경 시 Redis 캐시가 무효화되어 재배포 없이 반영됩니다.

DB 확인:

```bash
POD=$(kubectl -n llm-gateway get pods -l app.kubernetes.io/component=admin-api \
  --field-selector=status.phase=Running -o jsonpath='{.items[0].metadata.name}')
# select client, web_search_enabled from model.routing_profiles;
```

## 검증

```bash
# env
kubectl -n llm-gateway exec deploy/llm-gateway-gateway-proxy -- \
  env | grep -E 'AGENTCORE_|WEB_SEARCH_'

# status 스크립트
REGION=us-west-2 GW_NAME=awsome-ai-gw-websearch \
  python3 deployment/scripts/provision_agentcore_websearch.py status

# E2E: Claude Code / gateway 로 학습 컷오프 이후 사실 질문
# → 출처 URL 포함 답변, usage_logs.web_search_count 증가
```

기동 로그에 `agentcore_mcp_client_configured`가 보이면 MCP 클라이언트가 살아 있습니다. URL이 비어 있으면 해당 로그 0건(이전 prod 상태).

## 관련 파일

| 파일 | 역할 |
|------|------|
| `deployment/scripts/provision_agentcore_websearch.py` | Gateway + target + IAM 생성 |
| `deployment/charts/llm-gateway/values-eks-fargate-prod.yaml` | proxy env |
| `deployment/terraform/modules/irsa/main.tf` | InvokeGateway |
| `gateway-proxy/.../web_search_loop.py` | 툴 주입·가로채기·루프 |
| `gateway-proxy/.../agentcore_mcp_client.py` | MCP SigV4 호출 |
| `installer.md` | 배포 체크리스트 |
