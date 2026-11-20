# Copyright 2026 © Amazon.com and Affiliates: This deliverable is considered Developed Content as defined in the AWS Service Terms.

variable "project" {
  type        = string
  description = "Project prefix (예: dslg)"
}

variable "environment" {
  type        = string
  description = "환경 식별자 (dev | prod)"
}

variable "aws_region" {
  type        = string
  description = "AWS region (issuer URL 빌드에 사용)"
}

variable "domain_suffix" {
  type        = string
  description = "Hosted UI 도메인 prefix suffix. 최종 도메인: {project}-{env}-{suffix}.auth.{region}.amazoncognito.com (전 세계 unique 해야 함)"
  default     = "auth"
}

variable "callback_urls" {
  type        = list(string)
  description = "OIDC redirect URI 화이트리스트. gateway-cli 가 사용. 기본: localhost callback (PKCE)"
  default = [
    "http://localhost:8090/callback",
    "http://localhost:8091/callback",
    "http://localhost:8092/callback",
  ]
}

variable "logout_urls" {
  type        = list(string)
  description = "OIDC logout redirect URI 화이트리스트"
  default = [
    "http://localhost:8090/logout",
    "http://localhost:8091/logout",
    "http://localhost:8092/logout",
  ]
}

variable "groups" {
  type        = list(string)
  description = "User groups. 'Claude_<team>' 은 Default Department 하위 팀, 'Claude_<department>_<team>' 은 dept 자동 생성 후 team 매핑, ClaudeAdmin 은 admin 부트스트랩."
  default     = ["Claude_AI-Center_S/W-Culture-Office", "Claude_test-department_aws-test", "ClaudeAdmin"]
}

variable "enable_google_federation" {
  type        = bool
  description = "Cognito User Pool 에 Google IdP 를 추가하고 App Client 에 Google 을 노출한다. 포털(html/) Google 직접 로그인과는 별개 OAuth client 를 써야 한다."
  default     = false
}

variable "google_client_id" {
  type        = string
  description = "Google OAuth Web client ID (Cognito federation 전용). enable_google_federation=true 일 때 필수."
  default     = ""
}

variable "google_client_secret" {
  type        = string
  description = "Google OAuth Web client secret (Cognito federation 전용). enable_google_federation=true 일 때 필수."
  sensitive   = true
  default     = ""
}

variable "enable_pre_token_generation" {
  type        = bool
  description = "Pre Token Generation Lambda 로 Claude_* 팀 그룹이 없을 때 default_team_group 을 토큰(및 Cognito 멤버십)에 주입한다."
  default     = true
}

variable "default_team_group" {
  type        = string
  description = "팀 그룹이 없을 때 주입할 Cognito 그룹명 (admin-api OIDC_DEFAULT_TEAM_GROUP 과 동일해야 함)."
  default     = "Claude_AWS_Users"
}

variable "oidc_group_prefix" {
  type        = string
  description = "팀 그룹 prefix (admin-api OIDC_GROUP_PREFIX 와 동일)."
  default     = "Claude_"
}

variable "admin_group" {
  type        = string
  description = "관리자 부트스트랩 그룹명 (팀 매핑에서 제외)."
  default     = "ClaudeAdmin"
}

variable "tags" {
  type        = map(string)
  description = "Common tags"
  default     = {}
}
