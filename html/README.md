# 사용자 포털 (html/)

Google 계정으로 로그인해 **본인**의 API 키, 사용량, 예산을 보고 Gateway API를 시험하는 정적 사이트(S3 + CloudFront).

## 구조와 보안 경계

```
브라우저 ──Google ID token──▶ admin-api /portal/*  (서명·aud·exp·email_verified 검증 → auth.users 이메일 매칭)
        └──VK(Bearer)───────▶ gateway /v1/*        (기존 인증·예산·rate limit 그대로)
```

- **권한 판단은 브라우저가 아니라 서버가 한다.** 포털은 화면만 그린다.
- 프로비저닝하지 않는다: `auth.users`에 없는 이메일은 403 `user_not_provisioned`.
- 조회는 토큰에서 나온 user_id로만 한다(요청으로 user_id를 받는 경로 없음).
- Cognito 풀을 새로 만들지 않는다.

## 배포

```bash
# 1) 인프라 (최초 1회): terraform.tfvars 의 enable_portal=true
terraform -chdir=deployment/terraform/environments/llm-gateway-prod apply -target=module.portal_site
# 2) 정적 파일 업로드 + 캐시 무효화
bash html/deploy.sh
```

## 필수 설정

| 위치 | 값 |
|---|---|
| `html/config.js` | `googleClientId`, `adminApiUrl`, `gatewayUrl` |
| admin-api env | `PORTAL_GOOGLE_CLIENT_ID`, `CORS_ALLOW_ORIGINS=<포털 오리진>` |
| gateway-proxy env | `CORS_ALLOW_ORIGINS=<포털 오리진>` |
| Google Cloud Console | OAuth client 의 **Authorized JavaScript origins** 에 포털 오리진 추가 |

포털 오리진: `terraform output -raw portal_origin`. 커스텀 도메인으로 바꾸면 위 세 곳과 CSP(`modules/portal-site`)를 함께 바꾼다.

## 주의

- **새 키 발급은 기존 키를 즉시 만료**시킨다(사용자당 ACTIVE 키 1개). 재발급은 시간당 5회로 제한된다.
- 평문 키는 발급 응답에서 한 번만 보인다. 서버에서 다시 꺼낼 수 없다.
