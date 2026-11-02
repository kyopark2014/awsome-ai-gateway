// 배포 시 terraform output 으로 덮어쓴다(html/deploy.sh). 모두 공개 값이다 — 비밀이 없다.
window.PORTAL_CONFIG = {
  // Google OAuth Web client ID (공개 식별자)
  googleClientId: "57958713272-ncan3il8tq78lg2i1iq659rac9cem6k6.apps.googleusercontent.com",
  // admin-api 와 gateway 의 공개 URL (둘 다 이 포털 오리진을 CORS 로 허용해야 한다)
  adminApiUrl: "https://admin-api.my-agentic-ai.click",
  gatewayUrl: "https://llm.my-agentic-ai.click",
  projectName: "AWSome AI Gateway",
};
