# Catalog media (ingredient images under ingredients/, later products/ and so on) in a private
# bucket, served by its own CloudFront distribution at stable, unsigned URLs. The backend
# uploads every image under a new UUID key with "Cache-Control: public, max-age=31536000,
# immutable", so a key's content never changes and no invalidation is ever needed. A replaced
# or deleted image can stay in edge caches until evicted, which is fine for catalog pictures.
#
# A separate distribution rather than a path on the app's: the app distribution's 404 →
# index.html rule applies to every path, and its same-origin API setup stays untouched.
# The browser loads <img> from another origin without CORS, so the bucket has no CORS rules.

resource "aws_s3_bucket" "media" {
  bucket = "${local.name}-media-${local.account_id}"
}

resource "aws_s3_bucket_public_access_block" "media" {
  bucket = aws_s3_bucket.media.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# Both match S3's defaults for new buckets; declared so they're pinned
resource "aws_s3_bucket_ownership_controls" "media" {
  bucket = aws_s3_bucket.media.id

  rule {
    object_ownership = "BucketOwnerEnforced"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "media" {
  bucket = aws_s3_bucket.media.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_cloudfront_origin_access_control" "media" {
  name                              = "${local.name}-media"
  description                       = "CloudFront access to the private media bucket"
  origin_access_control_origin_type = "s3"
  signing_behavior                  = "always"
  signing_protocol                  = "sigv4"
}

locals {
  media_origin_id = "media-s3"
}

resource "aws_cloudfront_distribution" "media" {
  enabled         = true
  comment         = "${local.name}: catalog media from S3"
  is_ipv6_enabled = true
  http_version    = "http2and3"
  # Edge locations in Europe and North America only (the cheapest price class)
  price_class = "PriceClass_100"

  origin {
    origin_id                = local.media_origin_id
    domain_name              = aws_s3_bucket.media.bucket_regional_domain_name
    origin_access_control_id = aws_cloudfront_origin_access_control.media.id
  }

  # Images are already compressed. No custom error responses: a missing key is a plain 403.
  default_cache_behavior {
    target_origin_id           = local.media_origin_id
    viewer_protocol_policy     = "redirect-to-https"
    allowed_methods            = ["GET", "HEAD", "OPTIONS"]
    cached_methods             = ["GET", "HEAD"]
    compress                   = false
    cache_policy_id            = data.aws_cloudfront_cache_policy.caching_optimized.id
    response_headers_policy_id = data.aws_cloudfront_response_headers_policy.security_headers.id
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

# Read access for the media distribution only. Without s3:ListBucket, S3 answers a missing
# key with 403 rather than 404.
data "aws_iam_policy_document" "media_bucket" {
  statement {
    sid       = "CloudFrontReadMedia"
    actions   = ["s3:GetObject"]
    resources = ["${aws_s3_bucket.media.arn}/*"]

    principals {
      type        = "Service"
      identifiers = ["cloudfront.amazonaws.com"]
    }

    condition {
      test     = "StringEquals"
      variable = "AWS:SourceArn"
      values   = [aws_cloudfront_distribution.media.arn]
    }
  }
}

resource "aws_s3_bucket_policy" "media" {
  bucket = aws_s3_bucket.media.id
  policy = data.aws_iam_policy_document.media_bucket.json

  depends_on = [aws_s3_bucket_public_access_block.media]
}
