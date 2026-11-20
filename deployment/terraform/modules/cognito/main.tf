# Copyright 2026 © Amazon.com and Affiliates: This deliverable is considered Developed Content as defined in the AWS Service Terms.

# ==============================================================================
# Cognito User Pool — OIDC IDP for LLM Gateway
# ------------------------------------------------------------------------------
# - User Pool 1개 (env 별)
# - Public App Client (PKCE 강제, refresh token rotation)
# - Hosted UI 도메인 (`{prefix}.auth.{region}.amazoncognito.com`)
# - 선택: Google federation (포털 Google 직접 로그인과 별개 OAuth client)
# - 선택: Pre Token Generation — Claude_* 팀 그룹 없으면 default_team_group 주입
# - 사용자 그룹:
#   - Claude_<team>             → Default Department 하위 <team> 팀 자동 매핑
#   - Claude_<department>_<team> → <department> 부서 자동 생성 + 그 아래 <team> 팀
#   - ClaudeAdmin               → admin role 부트스트랩 (팀 매핑 제외)
#   - "Claude_" prefix 없는 그룹은 OIDC 로그인 거부 (REJECT_UNMATCHED_GROUPS=true)
#   (admin 이 콘솔에서 사용자를 그룹에 직접 추가)
#
# 토큰 형식 주의:
#   - Cognito access_token: 표준 OIDC `aud` claim 없음 (대신 client_id claim).
#     admin-api 의 OIDC_AUDIENCE 는 비워두고 audience 검증 skip 사용.
#   - issuer URL: https://cognito-idp.{region}.amazonaws.com/{user_pool_id}
# ==============================================================================

locals {
  user_pool_name = "${var.project}-${var.environment}-userpool"
  # google_client_secret 은 sensitive 라 boolean 표현에 넣으면 output 전체가 sensitive 가 된다.
  # IdP 생성 여부만 client_id 존재로 판정하고, secret 빈 값은 resource 쪽에서 실패하게 둔다.
  google_enabled = var.enable_google_federation && var.google_client_id != ""
  # default_team_group 이 groups 목록에 반드시 포함되도록 합친다.
  effective_groups = distinct(concat(var.groups, [var.default_team_group]))
  identity_providers = local.google_enabled ? ["COGNITO", "Google"] : ["COGNITO"]
}

# ------------------------------------------------------------------------------
# User Pool
# ------------------------------------------------------------------------------
resource "aws_cognito_user_pool" "this" {
  name = local.user_pool_name

  username_attributes      = ["email"]
  auto_verified_attributes = ["email"]

  password_policy {
    minimum_length                   = 12
    require_lowercase                = true
    require_uppercase                = true
    require_numbers                  = true
    require_symbols                  = false
    temporary_password_validity_days = 7
  }

  # MFA off (MVP — v2 에서 검토)
  mfa_configuration = "OFF"

  # 사용자 self-signup 차단 — admin 이 콘솔에서 직접 생성
  # (Google federation 사용자는 Cognito 가 첫 로그인 시 federated 프로필을 생성한다)
  admin_create_user_config {
    allow_admin_create_user_only = true
    invite_message_template {
      email_subject = "[LLM Gateway] 임시 자격증명"
      email_message = "안녕하세요, {username}.\n임시 패스워드: {####}\n\n첫 로그인 시 패스워드를 변경해주세요."
      sms_message   = "{username} 임시 패스워드: {####}"
    }
  }

  schema {
    name                = "email"
    attribute_data_type = "String"
    required            = true
    mutable             = true
    string_attribute_constraints {
      min_length = 1
      max_length = 320
    }
  }

  schema {
    name                = "name"
    attribute_data_type = "String"
    required            = false
    mutable             = true
    string_attribute_constraints {
      min_length = 0
      max_length = 255
    }
  }

  account_recovery_setting {
    recovery_mechanism {
      name     = "verified_email"
      priority = 1
    }
  }

  dynamic "lambda_config" {
    for_each = var.enable_pre_token_generation ? [1] : []
    content {
      pre_token_generation_config {
        lambda_arn     = aws_lambda_function.pre_token_gen[0].arn
        lambda_version = "V2_0"
      }
    }
  }

  tags = merge(var.tags, {
    Name        = local.user_pool_name
    Environment = var.environment
  })
}

# ------------------------------------------------------------------------------
# Hosted UI 도메인
# ------------------------------------------------------------------------------
resource "aws_cognito_user_pool_domain" "this" {
  domain       = "${var.project}-${var.environment}-${var.domain_suffix}"
  user_pool_id = aws_cognito_user_pool.this.id
}

# ------------------------------------------------------------------------------
# Google IdP (optional) — 포털 PORTAL_GOOGLE_CLIENT_ID 와 다른 OAuth client 권장
# ------------------------------------------------------------------------------
resource "aws_cognito_identity_provider" "google" {
  count = local.google_enabled ? 1 : 0

  user_pool_id  = aws_cognito_user_pool.this.id
  provider_name = "Google"
  provider_type = "Google"

  provider_details = {
    client_id        = var.google_client_id
    client_secret    = var.google_client_secret
    authorize_scopes = "profile email openid"
  }

  attribute_mapping = {
    email    = "email"
    username = "sub"
    name     = "name"
  }
}

# ------------------------------------------------------------------------------
# App Client — Public (PKCE 강제), gateway-cli 용
# ------------------------------------------------------------------------------
resource "aws_cognito_user_pool_client" "cli" {
  name         = "${var.project}-${var.environment}-cli"
  user_pool_id = aws_cognito_user_pool.this.id

  # Public client — secret 없음 (PKCE 로 보안)
  generate_secret = false

  # Authorization Code flow (PKCE 강제) + refresh
  allowed_oauth_flows                  = ["code"]
  allowed_oauth_flows_user_pool_client = true
  allowed_oauth_scopes                 = ["openid", "email", "profile"]
  supported_identity_providers         = local.identity_providers

  # Callback / logout URLs
  callback_urls = var.callback_urls
  logout_urls   = var.logout_urls

  # Token TTL — 우리 spec 의 권장값
  access_token_validity  = 1 # 1시간
  id_token_validity      = 1 # 1시간
  refresh_token_validity = 7 # 7일
  token_validity_units {
    access_token  = "hours"
    id_token      = "hours"
    refresh_token = "days"
  }

  # Refresh token rotation
  enable_token_revocation       = true
  prevent_user_existence_errors = "ENABLED"

  # API 호출용 Auth flows (테스트 ROPC 허용)
  explicit_auth_flows = [
    "ALLOW_USER_SRP_AUTH",
    "ALLOW_REFRESH_TOKEN_AUTH",
    "ALLOW_USER_PASSWORD_AUTH", # admin 이 직접 사용자 생성 후 임시 PW 사용
  ]

  read_attributes  = ["email", "email_verified", "name"]
  write_attributes = ["email", "name"]

  depends_on = [aws_cognito_identity_provider.google]
}

# ------------------------------------------------------------------------------
# 사용자 그룹 (terraform 으로 미리 생성, admin 이 사용자를 콘솔에서 추가)
# ------------------------------------------------------------------------------
resource "aws_cognito_user_group" "groups" {
  for_each = toset(local.effective_groups)

  user_pool_id = aws_cognito_user_pool.this.id
  name         = each.value
  description  = "LLM Gateway team mapping group"
}

# ------------------------------------------------------------------------------
# Pre Token Generation Lambda — default team group 주입
# ------------------------------------------------------------------------------
data "archive_file" "pre_token_gen" {
  count       = var.enable_pre_token_generation ? 1 : 0
  type        = "zip"
  source_file = "${path.module}/lambda/pre_token_gen/handler.py"
  output_path = "${path.module}/lambda/pre_token_gen/handler.zip"
}

resource "aws_iam_role" "pre_token_gen" {
  count = var.enable_pre_token_generation ? 1 : 0
  name  = "${var.project}-${var.environment}-cognito-pre-token"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "lambda.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })

  tags = var.tags
}

resource "aws_iam_role_policy" "pre_token_gen" {
  count = var.enable_pre_token_generation ? 1 : 0
  name  = "cognito-admin-add-to-group"
  role  = aws_iam_role.pre_token_gen[0].id

  # User pool ARN 을 직접 참조하면 lambda ↔ pool 순환 의존이 생긴다.
  # 동일 계정의 cognito-idp 로 한정하고, 로그는 함수명 prefix 로 제한한다.
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = ["cognito-idp:AdminAddUserToGroup"]
        Resource = "arn:aws:cognito-idp:${var.aws_region}:*:userpool/*"
      },
      {
        Effect = "Allow"
        Action = [
          "logs:CreateLogGroup",
          "logs:CreateLogStream",
          "logs:PutLogEvents",
        ]
        Resource = "arn:aws:logs:${var.aws_region}:*:log-group:/aws/lambda/${var.project}-${var.environment}-cognito-pre-token*"
      },
    ]
  })
}

resource "aws_lambda_function" "pre_token_gen" {
  count = var.enable_pre_token_generation ? 1 : 0

  function_name    = "${var.project}-${var.environment}-cognito-pre-token"
  role             = aws_iam_role.pre_token_gen[0].arn
  handler          = "handler.handler"
  runtime          = "python3.12"
  filename         = data.archive_file.pre_token_gen[0].output_path
  source_code_hash = data.archive_file.pre_token_gen[0].output_base64sha256
  timeout          = 10
  memory_size      = 128

  environment {
    variables = {
      OIDC_GROUP_PREFIX       = var.oidc_group_prefix
      OIDC_DEFAULT_TEAM_GROUP = var.default_team_group
      ADMIN_GROUP             = var.admin_group
    }
  }

  tags = var.tags

  depends_on = [aws_iam_role_policy.pre_token_gen]
}

resource "aws_lambda_permission" "pre_token_gen" {
  count = var.enable_pre_token_generation ? 1 : 0

  statement_id  = "AllowCognitoInvoke"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.pre_token_gen[0].function_name
  principal     = "cognito-idp.amazonaws.com"
  source_arn    = aws_cognito_user_pool.this.arn
}
