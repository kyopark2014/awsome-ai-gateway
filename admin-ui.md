# Admin UI / Admin API — HTTPS (prod)

Admin 콘솔과 Virtual Key API를 `my-agentic-ai.click` 하위 도메인으로 HTTPS 제공합니다.  
Gateway(`llm.my-agentic-ai.click`)와 동일하게 **gateway 계정(262976740991) ACM + stock Route53 alias** 패턴입니다.

## 최종 URL

| 서비스 | URL | health |
|--------|-----|--------|
| Admin UI | https://admin.my-agentic-ai.click | `/api/health` → `{"status":"ok","service":"admin-ui"}` |
| Admin API | https://admin-api.my-agentic-ai.click | `/health` → `{"status":"alive"}` |
| Gateway Proxy | https://llm.my-agentic-ai.click | `/health` → 200 |

HTTP(80)는 ALB `ssl-redirect: "443"`으로 HTTPS로 301 됩니다.

ALB DNS (alias 대상, 직접 쓰지 않음):

| 서비스 | ALB |
|--------|-----|
| Admin UI | `k8s-llmgatew-llmgatew-da07b044a7-48764743.ap-northeast-2.elb.amazonaws.com` |
| Admin API | `k8s-llmgatew-llmgatew-4e06a94bc4-1287247182.ap-northeast-2.elb.amazonaws.com` |

## ACM

| 항목 | 값 |
|------|-----|
| Account / Region | `262976740991` / `ap-northeast-2` |
| ARN | `arn:aws:acm:ap-northeast-2:262976740991:certificate/6787130d-d1bf-4e77-905a-e2f313e86b74` |
| SANs | `admin.my-agentic-ai.click`, `admin-api.my-agentic-ai.click` |
| 검증 | DNS (stock Route53 `my-agentic-ai.click`) |
| Status | `ISSUED` |

Gateway용 ACM(`8dfcd933-…`, `llm.my-agentic-ai.click`)과 **별도** 인증서입니다. Admin UI·API는 한 장의 SAN 인증서를 공유합니다.

## DNS (stock Route53)

Hosted zone: `Z04327013V8HP1JSXPGNM` (`my-agentic-ai.click`, stock 계정).

| 레코드 | 타입 | 대상 |
|--------|------|------|
| `admin.my-agentic-ai.click` | A (Alias) | Admin UI ALB |
| `admin-api.my-agentic-ai.click` | A (Alias) | Admin API ALB |

ACM 검증 CNAME도 동일 zone에 둡니다.

## Helm values

파일: `deployment/charts/llm-gateway/values-eks-fargate-prod.yaml`

```yaml
ingress:
  adminUi:
    host: "admin.my-agentic-ai.click"
    tls:
      enabled: false   # K8s TLS Secret 미사용 — ACM은 어노테이션
    annotations:
      alb.ingress.kubernetes.io/listen-ports: '[{"HTTP":80},{"HTTPS":443}]'
      alb.ingress.kubernetes.io/ssl-policy: ELBSecurityPolicy-TLS13-1-2-2021-06
      alb.ingress.kubernetes.io/ssl-redirect: "443"
      alb.ingress.kubernetes.io/certificate-arn: "arn:aws:acm:ap-northeast-2:262976740991:certificate/6787130d-d1bf-4e77-905a-e2f313e86b74"
  adminApi:
    host: "admin-api.my-agentic-ai.click"
    tls:
      enabled: false
    annotations:
      # 동일 ACM SAN + listen-ports / ssl-redirect
      alb.ingress.kubernetes.io/certificate-arn: "arn:aws:acm:ap-northeast-2:262976740991:certificate/6787130d-d1bf-4e77-905a-e2f313e86b74"

adminUi:
  nextauthUrl: "https://admin.my-agentic-ai.click"  # NEXTAUTH_URL — tls.enabled=false 라도 필수
```

적용 예 (기존 값 유지, ExternalSecret/hooks 충돌 시):

```bash
helm upgrade llm-gateway deployment/charts/llm-gateway \
  -n llm-gateway -f deployment/charts/llm-gateway/values-eks-fargate-prod.yaml \
  --reuse-values --no-hooks
```

`ingress.*.tls.enabled=true`로 올리면 Chart가 TLS Secret을 기대할 수 있습니다. prod는 **ACM ARN 어노테이션 + `nextauthUrl` https** 조합을 씁니다.

## Cognito (SSO)

User Pool `ap-northeast-2_xa33nFlY3` / Client `l5b47iln436rs5ejdcvo17gt7`.

| 항목 | HTTPS URL |
|------|-----------|
| Callback | `https://admin.my-agentic-ai.click/api/auth/callback` |
| Logout | `https://admin.my-agentic-ai.click/` |

localhost(`3000` Admin UI port-forward, `8090~8092` gateway-cli) 콜백은 유지합니다.

CLI / 스크립트용 Admin API:

```bash
export ADMIN_API_URL="https://admin-api.my-agentic-ai.click"
```

`config.json`의 `admin_api_url`도 동일합니다.

## 접속 절차 (운영자)

1. (최초 1회) Cognito JWKS → `auth.admin_jwt_configs` + placeholder 비활성 — `installer.md` ①
2. `gateway-cli login`으로 `auth.users` 프로비저닝 — ②
3. 브라우저에서 **https://admin.my-agentic-ai.click** 로그인 (port-forward 불필요)
4. (선택) Users → Cognito 동기화 · 팀 예산 활성화

Admin UI 세션은 `admin_jwt` 쿠키 + admin-api PEM 검증입니다. OIDC JWKS fallback은 설계상 없습니다.

## 검증

```bash
curl -sS https://admin-api.my-agentic-ai.click/health
# {"status":"alive"}

curl -sS https://admin.my-agentic-ai.click/api/health
# {"status":"ok","service":"admin-ui"}

curl -sS -o /dev/null -w '%{http_code} %{redirect_url}\n' http://admin-api.my-agentic-ai.click/health
# 301 https://admin-api.my-agentic-ai.click:443/health
```

배포 직후 ALB에 443 리스너가 붙기까지 1~2분 걸릴 수 있습니다.

## 관련 파일

| 파일 | 역할 |
|------|------|
| `deployment/charts/llm-gateway/values-eks-fargate-prod.yaml` | host / ACM / nextauthUrl |
| `config.json` | `admin_api_url` (로컬 스크립트, gitignore) |
| `manual_users.md` | 사용자 `ADMIN_API_URL` 안내 |
| `installer.md` | 배포 기록·SSO 절차 |
