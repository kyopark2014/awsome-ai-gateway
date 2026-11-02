# Copyright 2026 © Amazon.com and Affiliates: This deliverable is considered Developed Content as defined in the AWS Service Terms.

output "bucket_name" {
  value       = aws_s3_bucket.site.bucket
  description = "정적 파일을 올릴 S3 버킷"
}

output "distribution_id" {
  value       = aws_cloudfront_distribution.site.id
  description = "배포 후 invalidation 대상 CloudFront 배포 ID"
}

output "cloudfront_domain" {
  value       = aws_cloudfront_distribution.site.domain_name
  description = "기본 CloudFront 도메인 (DNS 없이 바로 접속 가능)"
}

output "portal_origin" {
  value       = local.use_domain ? "https://${var.domain_name}" : "https://${aws_cloudfront_distribution.site.domain_name}"
  description = "포털 오리진 — admin-api / gateway 의 CORS_ALLOW_ORIGINS 와 Google OAuth 'Authorized JavaScript origins' 에 등록할 값"
}
