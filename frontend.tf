# One CloudFront distribution serves both the Angular app (private S3 bucket) and the API
# (/api/* to Beanstalk), so the browser sees a single HTTPS address and no CORS is needed.
# scripts/deploy-frontend.sh uploads the build and invalidates the cache.

resource "aws_s3_bucket" "frontend" {
  bucket = "${local.name}-frontend-${local.account_id}"
}

resource "aws_s3_bucket_public_access_block" "frontend" {
  bucket = aws_s3_bucket.frontend.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_cloudfront_origin_access_control" "frontend" {
  name                              = "${local.name}-frontend"
  description                       = "CloudFront access to the private frontend bucket"
  origin_access_control_origin_type = "s3"
  signing_behavior                  = "always"
  signing_protocol                  = "sigv4"
}

data "aws_cloudfront_cache_policy" "caching_optimized" {
  name = "Managed-CachingOptimized"
}

data "aws_cloudfront_cache_policy" "caching_disabled" {
  name = "Managed-CachingDisabled"
}

# Forwards every viewer header (Authorization included) except Host
data "aws_cloudfront_origin_request_policy" "all_viewer_except_host" {
  name = "Managed-AllViewerExceptHostHeader"
}

data "aws_cloudfront_response_headers_policy" "security_headers" {
  name = "Managed-SecurityHeadersPolicy"
}

locals {
  frontend_origin_id = "frontend-s3"
  backend_origin_id  = "backend-beanstalk"
}

resource "aws_cloudfront_distribution" "main" {
  enabled             = true
  comment             = "${local.name}: Angular app from S3, /api/* to Beanstalk"
  default_root_object = "index.html"
  is_ipv6_enabled     = true
  http_version        = "http2and3"
  # Edge locations in Europe and North America only (the cheapest price class)
  price_class = "PriceClass_100"

  origin {
    origin_id                = local.frontend_origin_id
    domain_name              = aws_s3_bucket.frontend.bucket_regional_domain_name
    origin_access_control_id = aws_cloudfront_origin_access_control.frontend.id
  }

  # Plain HTTP to the instance: AWS can't issue a certificate for *.elasticbeanstalk.com,
  # and the viewer side stays HTTPS. Changes with the load balancer and a custom domain.
  origin {
    origin_id   = local.backend_origin_id
    domain_name = aws_elastic_beanstalk_environment.backend.cname

    custom_origin_config {
      http_port              = 80
      https_port             = 443
      origin_protocol_policy = "http-only"
      origin_ssl_protocols   = ["TLSv1.2"]
    }
  }

  default_cache_behavior {
    target_origin_id           = local.frontend_origin_id
    viewer_protocol_policy     = "redirect-to-https"
    allowed_methods            = ["GET", "HEAD", "OPTIONS"]
    cached_methods             = ["GET", "HEAD"]
    compress                   = true
    cache_policy_id            = data.aws_cloudfront_cache_policy.caching_optimized.id
    response_headers_policy_id = data.aws_cloudfront_response_headers_policy.security_headers.id
  }

  # API and Swagger UI (/api/swagger-ui.html): never cached
  ordered_cache_behavior {
    path_pattern               = "/api/*"
    target_origin_id           = local.backend_origin_id
    viewer_protocol_policy     = "https-only"
    allowed_methods            = ["DELETE", "GET", "HEAD", "OPTIONS", "PATCH", "POST", "PUT"]
    cached_methods             = ["GET", "HEAD"]
    compress                   = true
    cache_policy_id            = data.aws_cloudfront_cache_policy.caching_disabled.id
    origin_request_policy_id   = data.aws_cloudfront_origin_request_policy.all_viewer_except_host.id
    response_headers_policy_id = data.aws_cloudfront_response_headers_policy.security_headers.id
  }

  # Opening or refreshing an Angular route (/main/products) asks S3 for a file that doesn't
  # exist; answer with index.html so Angular shows the page. This rule applies to the whole
  # distribution, so only 404 is caught: the backend's 403s pass through untouched, and its
  # only 404 (GET of one entry by an unknown id) isn't used by the app.
  custom_error_response {
    error_code            = 404
    response_code         = 200
    response_page_path    = "/index.html"
    error_caching_min_ttl = 10
  }

  restrictions {
    geo_restriction {
      restriction_type = "none"
    }
  }

  viewer_certificate {
    cloudfront_default_certificate = true
  }
}

data "aws_iam_policy_document" "frontend_bucket" {
  statement {
    sid       = "CloudFrontReadFiles"
    actions   = ["s3:GetObject"]
    resources = ["${aws_s3_bucket.frontend.arn}/*"]

    principals {
      type        = "Service"
      identifiers = ["cloudfront.amazonaws.com"]
    }

    condition {
      test     = "StringEquals"
      variable = "AWS:SourceArn"
      values   = [aws_cloudfront_distribution.main.arn]
    }
  }

  # With list permission S3 answers 404 instead of 403 for a missing file, which the
  # 404 → index.html rule above relies on. The default root object keeps "/" from
  # returning a listing; the bucket only holds the public app files anyway.
  statement {
    sid       = "CloudFrontListForRealNotFound"
    actions   = ["s3:ListBucket"]
    resources = [aws_s3_bucket.frontend.arn]

    principals {
      type        = "Service"
      identifiers = ["cloudfront.amazonaws.com"]
    }

    condition {
      test     = "StringEquals"
      variable = "AWS:SourceArn"
      values   = [aws_cloudfront_distribution.main.arn]
    }
  }
}

resource "aws_s3_bucket_policy" "frontend" {
  bucket = aws_s3_bucket.frontend.id
  policy = data.aws_iam_policy_document.frontend_bucket.json

  depends_on = [aws_s3_bucket_public_access_block.frontend]
}
