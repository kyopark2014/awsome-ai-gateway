# Copyright 2026 © Amazon.com and Affiliates: This deliverable is considered Developed Content as defined in the AWS Service Terms.

# ==============================================================================
# 사용자 포털 정적 사이트 — S3(비공개) + CloudFront(OAC)
# ------------------------------------------------------------------------------
# - 버킷은 완전 비공개. CloudFront OAC(SigV4)만 읽을 수 있다.
# - 인증·권한은 이 계층이 아니라 admin-api / gateway 가 강제한다(브라우저는 화면만 그린다).
# - 응답 헤더 정책으로 CSP·HSTS·nosniff 등을 건다. CSP 의 connect-src 는 API 오리진만 허용한다.
# - domain_name 이 비어 있으면 기본 cloudfront.net 도메인으로 동작한다(DNS·인증서 불필요).
# ==============================================================================

locals {
  name       = "${var.project}-${var.environment}-portal"
  use_domain = var.domain_name != ""
}

data "aws_caller_identity" "current" {}

resource "aws_s3_bucket" "site" {
  bucket = "${local.name}-${data.aws_caller_identity.current.account_id}"
  tags   = merge(var.tags, { Name = local.name })
}

resource "aws_s3_bucket_public_access_block" "site" {
  bucket                  = aws_s3_bucket.site.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_ownership_controls" "site" {
  bucket = aws_s3_bucket.site.id
  rule {
    object_ownership = "BucketOwnerEnforced"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "site" {
  bucket = aws_s3_bucket.site.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_cloudfront_origin_access_control" "site" {
  name                              = local.name
  description                       = "OAC for ${local.name}"
  origin_access_control_origin_type = "s3"
  signing_behavior                  = "always"
  signing_protocol                  = "sigv4"
}

# 관리형 정책: CachingOptimized 가 아니라 CachingDisabled 를 쓰지 않는다 — 정적 파일은 짧게 캐시하고
# 배포 시 invalidation 한다. (config.js 가 배포마다 바뀌므로 TTL 을 짧게 둔다.)
resource "aws_cloudfront_cache_policy" "site" {
  name        = "${local.name}-short"
  comment     = "Short TTL for static portal assets"
  default_ttl = 300
  max_ttl     = 3600
  min_ttl     = 0

  parameters_in_cache_key_and_forwarded_to_origin {
    cookies_config {
      cookie_behavior = "none"
    }
    headers_config {
      header_behavior = "none"
    }
    query_strings_config {
      query_string_behavior = "none"
    }
    enable_accept_encoding_gzip   = true
    enable_accept_encoding_brotli = true
  }
}

resource "aws_cloudfront_response_headers_policy" "site" {
  name    = "${local.name}-security"
  comment = "Security headers for the user portal"

  security_headers_config {
    content_type_options {
      override = true
    }
    frame_options {
      frame_option = "DENY"
      override     = true
    }
    referrer_policy {
      referrer_policy = "no-referrer"
      override        = true
    }
    strict_transport_security {
      access_control_max_age_sec = 31536000
      include_subdomains         = true
      override                   = true
    }
    content_security_policy {
      override = true
      # script: 자기 자신 + Google Identity Services. connect: 자기 자신 + API 오리진(config.js 의 값과 일치해야 한다).
      content_security_policy = join("; ", [
        "default-src 'self'",
        "script-src 'self' https://accounts.google.com",
        "style-src 'self' https://fonts.googleapis.com https://accounts.google.com 'unsafe-inline'",
        "font-src https://fonts.gstatic.com",
        "img-src 'self' data: https://*.googleusercontent.com",
        "frame-src https://accounts.google.com",
        "connect-src 'self' https://*.my-agentic-ai.click https://accounts.google.com",
        "base-uri 'none'",
        "form-action 'none'",
        "frame-ancestors 'none'",
      ])
    }
  }
}

resource "aws_cloudfront_distribution" "site" {
  enabled             = true
  is_ipv6_enabled     = true
  comment             = local.name
  default_root_object = "index.html"
  price_class         = var.price_class
  aliases             = local.use_domain ? [var.domain_name] : []

  origin {
    domain_name              = aws_s3_bucket.site.bucket_regional_domain_name
    origin_id                = "s3-site"
    origin_access_control_id = aws_cloudfront_origin_access_control.site.id
  }

  default_cache_behavior {
    target_origin_id           = "s3-site"
    viewer_protocol_policy     = "redirect-to-https"
    allowed_methods            = ["GET", "HEAD", "OPTIONS"]
    cached_methods             = ["GET", "HEAD"]
    compress                   = true
    cache_policy_id            = aws_cloudfront_cache_policy.site.id
    response_headers_policy_id = aws_cloudfront_response_headers_policy.site.id
  }

  restrictions {
    geo_restriction {
      restriction_type = "none"
    }
  }

  viewer_certificate {
    cloudfront_default_certificate = local.use_domain ? null : true
    acm_certificate_arn            = local.use_domain ? var.acm_certificate_arn : null
    ssl_support_method             = local.use_domain ? "sni-only" : null
    minimum_protocol_version       = local.use_domain ? "TLSv1.2_2021" : null
  }

  lifecycle {
    precondition {
      condition     = !local.use_domain || var.acm_certificate_arn != ""
      error_message = "domain_name 을 쓰려면 us-east-1 acm_certificate_arn 이 필요합니다."
    }
  }

  tags = merge(var.tags, { Name = local.name })
}

# CloudFront(이 배포)만 버킷을 읽을 수 있다.
data "aws_iam_policy_document" "site" {
  statement {
    sid       = "AllowCloudFrontOAC"
    actions   = ["s3:GetObject"]
    resources = ["${aws_s3_bucket.site.arn}/*"]
    principals {
      type        = "Service"
      identifiers = ["cloudfront.amazonaws.com"]
    }
    condition {
      test     = "StringEquals"
      variable = "AWS:SourceArn"
      values   = [aws_cloudfront_distribution.site.arn]
    }
  }
  statement {
    sid       = "DenyInsecureTransport"
    effect    = "Deny"
    actions   = ["s3:*"]
    resources = [aws_s3_bucket.site.arn, "${aws_s3_bucket.site.arn}/*"]
    principals {
      type        = "*"
      identifiers = ["*"]
    }
    condition {
      test     = "Bool"
      variable = "aws:SecureTransport"
      values   = ["false"]
    }
  }
}

resource "aws_s3_bucket_policy" "site" {
  bucket     = aws_s3_bucket.site.id
  policy     = data.aws_iam_policy_document.site.json
  depends_on = [aws_s3_bucket_public_access_block.site]
}
