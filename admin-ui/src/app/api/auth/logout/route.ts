// Copyright 2026 © Amazon.com and Affiliates: This deliverable is considered Developed Content as defined in the AWS Service Terms.

/**
 * Logout route — clears the admin_jwt cookie and redirects to '/'.
 *
 * Mirrors the proto/host handling in dev-login/route.ts so the Set-Cookie
 * `secure` flag matches the actual connection scheme (HTTP vs HTTPS) and
 * the redirect URL preserves the original Host header (avoids 0.0.0.0 in
 * containerized envs). The redirect lands on '/' which middleware then
 * sends to '/api/auth/login' since the cookie is gone — that route picks the
 * OIDC authorize URL, the dev form, or a readable 503 depending on env
 * (src/app/api/auth/login/route.ts). It used to point straight at
 * '/api/auth/dev-login', which answers a bodyless 404 in prod.
 */

import { NextRequest, NextResponse } from 'next/server';
import { redirectRelative } from '@/lib/redirect';

export async function POST(request: NextRequest): Promise<NextResponse> {
  // host 는 더 필요 없다 — 리다이렉트가 상대 경로다(lib/redirect.ts). proto 는 쿠키의
  // Secure 플래그 판정에 여전히 쓴다(HTTP 종단에서 Secure 를 붙이면 쿠키가 저장 안 된다).
  const proto = request.headers.get('x-forwarded-proto') || 'http';

  // 상대 Location — Host 헤더가 CloudFront 뒤에서 ALB 이름일 수 있다(lib/redirect.ts).
  const response = redirectRelative('/');
  response.cookies.set('admin_jwt', '', {
    httpOnly: true,
    sameSite: 'lax',
    path: '/',
    maxAge: 0,
    secure: proto === 'https',
  });
  // IdP(Cognito Hosted UI) 세션은 admin_jwt 를 지워도 남는다. 그대로 두면 다음 /api/auth/login 의
  // authorize 가 로그인 화면 없이 곧바로 코드를 줘서 "로그아웃이 안 된 것처럼" 보인다.
  // 1회용 플래그를 심어 login 라우트가 prompt=login 으로 재인증을 강제하게 한다.
  response.cookies.set('oidc_force_login', '1', {
    httpOnly: true,
    sameSite: 'lax',
    path: '/',
    maxAge: 600,
    secure: proto === 'https',
  });
  response.headers.set('Cache-Control', 'no-store');

  // OIDC_LOGOUT_URL(예: https://<domain>.auth.<region>.amazoncognito.com/logout)이 설정돼 있으면
  // IdP 세션까지 종료한다. logout_uri 는 Cognito App Client 의 Allowed sign-out URLs 에
  // 정확히 일치하게 등록돼 있어야 한다(미등록이면 Cognito 가 오류 페이지를 낸다 — 그래서 opt-in).
  const logoutUrl = (process.env.OIDC_LOGOUT_URL ?? '').trim();
  const clientId = (process.env.OIDC_CLIENT_ID ?? '').trim();
  if (logoutUrl && clientId) {
    try {
      const host = request.headers.get('host') || 'localhost:3000';
      const logoutUri =
        (process.env.OIDC_LOGOUT_REDIRECT_URI ?? '').trim() ||
        `${proto.split(',')[0].trim()}://${host}/`;
      const u = new URL(logoutUrl);
      u.searchParams.set('client_id', clientId);
      u.searchParams.set('logout_uri', logoutUri);
      const out = NextResponse.redirect(u.toString(), { status: 303 });
      out.headers.set('Cache-Control', 'no-store');
      for (const c of response.cookies.getAll()) out.cookies.set(c);
      return out;
    } catch {
      // 잘못된 OIDC_LOGOUT_URL — 로컬 로그아웃 + prompt=login 폴백으로 진행.
    }
  }
  return response;
}
