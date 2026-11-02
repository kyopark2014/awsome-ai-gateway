#!/usr/bin/env bash
# Copyright 2026 © Amazon.com and Affiliates: This deliverable is considered Developed Content as defined in the AWS Service Terms.
#
# 사용자 포털 정적 파일을 S3 에 올리고 CloudFront 캐시를 비운다.
#   사용: bash html/deploy.sh
# 버킷/배포 ID 는 terraform output 에서 읽는다(PORTAL_BUCKET / PORTAL_DISTRIBUTION_ID 로 덮어쓸 수 있음).
set -euo pipefail
cd "$(dirname "$0")"

TF_DIR="../deployment/terraform/environments/${ENV:-llm-gateway-prod}"
BUCKET="${PORTAL_BUCKET:-$(terraform -chdir="$TF_DIR" output -raw portal_bucket)}"
DIST="${PORTAL_DISTRIBUTION_ID:-$(terraform -chdir="$TF_DIR" output -raw portal_distribution_id)}"
[ -n "$BUCKET" ] && [ "$BUCKET" != "null" ] || { echo "portal_bucket 을 찾을 수 없습니다 (enable_portal=true 로 apply 했나요?)" >&2; exit 1; }

echo "→ s3://$BUCKET"
# 정적 자산은 짧게 캐시하고, 자주 바뀌는 index.html / config.js 는 no-cache 로 다시 올린다.
aws s3 sync . "s3://$BUCKET" --delete \
  --exclude "deploy.sh" --exclude "README.md" --exclude ".DS_Store" \
  --cache-control "public, max-age=300"
aws s3 cp index.html "s3://$BUCKET/index.html" --content-type "text/html; charset=utf-8" --cache-control "no-cache"
aws s3 cp config.js  "s3://$BUCKET/config.js"  --content-type "application/javascript; charset=utf-8" --cache-control "no-cache"

echo "→ CloudFront invalidation ($DIST)"
aws cloudfront create-invalidation --distribution-id "$DIST" --paths "/*" --query 'Invalidation.Id' --output text
echo "완료."
