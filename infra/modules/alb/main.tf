data "aws_caller_identity" "current" {}

# The regional account that writes ALB access logs. Correct for Mumbai; AWS Regions opened since
# Jakarta (Dec 2021) need a service principal instead (see the provider docs for this data source).
data "aws_elb_service_account" "this" {}

locals {
  log_prefix = "alb"
}

# ---------- access log bucket ----------
resource "aws_s3_bucket" "logs" {
  #checkov:skip=CKV_AWS_144:A single region is enough for this project, and these logs expire; replication would only add cost.
  #checkov:skip=CKV_AWS_145:Load balancer access logs support SSE-S3 only, not KMS, so AES256 is the strongest option.
  #checkov:skip=CKV_AWS_18:This bucket is itself the log destination; logging it too would need yet another bucket.
  #checkov:skip=CKV_AWS_21:The logs expire after the retention period; versioning would keep deleted versions and add cost.
  #checkov:skip=CKV2_AWS_62:There is no consumer for bucket event notifications.
  bucket        = "${var.name_prefix}-alb-logs-${data.aws_caller_identity.current.account_id}"
  force_destroy = !var.deletion_protection # prod (protection on) keeps its logs; staging destroys cleanly
}

resource "aws_s3_bucket_public_access_block" "logs" {
  bucket                  = aws_s3_bucket.logs.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_server_side_encryption_configuration" "logs" {
  bucket = aws_s3_bucket.logs.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256" # ALB access logs support SSE-S3 only, not KMS
    }
  }
}

resource "aws_s3_bucket_lifecycle_configuration" "logs" {
  bucket = aws_s3_bucket.logs.id
  rule {
    id     = "expire-access-logs"
    status = "Enabled"
    filter {}
    expiration {
      days = var.access_log_retention_days
    }
    abort_incomplete_multipart_upload {
      days_after_initiation = 7
    }
  }
}

data "aws_iam_policy_document" "logs" {
  statement {
    sid       = "AllowLoadBalancerToWriteLogs"
    actions   = ["s3:PutObject"]
    resources = ["${aws_s3_bucket.logs.arn}/${local.log_prefix}/AWSLogs/${data.aws_caller_identity.current.account_id}/*"]
    principals {
      type        = "AWS"
      identifiers = [data.aws_elb_service_account.this.arn]
    }
  }

  statement {
    sid       = "DenyNonTLSRequests"
    effect    = "Deny"
    actions   = ["s3:*"]
    resources = [aws_s3_bucket.logs.arn, "${aws_s3_bucket.logs.arn}/*"]
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

resource "aws_s3_bucket_policy" "logs" {
  bucket     = aws_s3_bucket.logs.id
  policy     = data.aws_iam_policy_document.logs.json
  depends_on = [aws_s3_bucket_public_access_block.logs]
}

# ---------- load balancer ----------
resource "aws_lb" "this" {
  #checkov:skip=CKV2_AWS_20:There is no domain, so no certificate and no HTTPS to redirect to; see "HTTP only for now" in the README.
  #checkov:skip=CKV2_AWS_28:A web application firewall costs extra and is out of scope for this project; listed under Accepted findings.
  #checkov:skip=CKV_AWS_150:Deletion protection is the deletion_protection variable: off in staging so it can be destroyed, on in production.
  name                       = "${var.name_prefix}-alb"
  load_balancer_type         = "application"
  internal                   = false
  security_groups            = [var.security_group_id]
  subnets                    = var.public_subnet_ids
  drop_invalid_header_fields = true
  enable_deletion_protection = var.deletion_protection

  access_logs {
    bucket  = aws_s3_bucket.logs.id
    prefix  = local.log_prefix
    enabled = true
  }

  # The load balancer test-writes to the bucket when it is created, so the policy must exist first.
  depends_on = [aws_s3_bucket_policy.logs]
}

# ---------- target groups ----------
resource "aws_lb_target_group" "frontend" {
  #checkov:skip=CKV_AWS_378:Traffic from the load balancer to the instances stays inside the VPC; HTTPS to the instances is out of scope.
  name                 = "${var.name_prefix}-fe-tg" # target group names are limited to 32 characters
  port                 = var.frontend_port
  protocol             = "HTTP"
  vpc_id               = var.vpc_id
  target_type          = "instance"
  deregistration_delay = var.deregistration_delay

  health_check {
    path                = var.frontend_health_check_path
    matcher             = "200"
    interval            = 15
    timeout             = 5
    healthy_threshold   = 2 # healthy after about 30 seconds
    unhealthy_threshold = 3 # removed after about 45 seconds
  }
}

resource "aws_lb_target_group" "backend" {
  #checkov:skip=CKV_AWS_378:Traffic from the load balancer to the instances stays inside the VPC; HTTPS to the instances is out of scope.
  name                 = "${var.name_prefix}-be-tg"
  port                 = var.backend_port
  protocol             = "HTTP"
  vpc_id               = var.vpc_id
  target_type          = "instance"
  deregistration_delay = var.deregistration_delay

  health_check {
    path                = var.backend_health_check_path
    matcher             = "200"
    interval            = 15
    timeout             = 5
    healthy_threshold   = 2
    unhealthy_threshold = 3
  }
}

# ---------- listener and routing ----------
resource "aws_lb_listener" "http" {
  #checkov:skip=CKV_AWS_2:HTTP only until a domain exists to get a certificate for; see "HTTP only for now" in the README.
  #checkov:skip=CKV_AWS_103:There is no HTTPS listener yet, so there is no TLS policy to set.
  load_balancer_arn = aws_lb.this.arn
  port              = 80
  protocol          = "HTTP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.frontend.arn
  }
}

resource "aws_lb_listener_rule" "api" {
  listener_arn = aws_lb_listener.http.arn
  priority     = 10

  condition {
    path_pattern {
      values = ["/api", "/api/*"] # the app already serves under /api, so no rewrite is needed
    }
  }

  action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.backend.arn
  }
}
