# Copyright 2026 © Amazon.com and Affiliates: This deliverable is considered Developed Content as defined in the AWS Service Terms.

variable "project" {
  type        = string
  description = "프로젝트 이름 (리소스 이름 prefix)"
}

variable "environment" {
  type        = string
  description = "환경 이름 (prod 등)"
}

variable "domain_name" {
  type        = string
  default     = ""
  description = "커스텀 도메인 (예: portal.my-agentic-ai.click). 빈 값이면 기본 *.cloudfront.net 도메인만 쓴다."
}

variable "acm_certificate_arn" {
  type        = string
  default     = ""
  description = "us-east-1 ACM 인증서 ARN. domain_name 을 쓸 때 필수."
}

variable "price_class" {
  type        = string
  default     = "PriceClass_200"
  description = "CloudFront price class (PriceClass_200 에 서울 엣지 포함)"
}

variable "tags" {
  type        = map(string)
  default     = {}
  description = "Common tags"
}
