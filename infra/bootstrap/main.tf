provider "aws" {
  region = var.aws_region
  default_tags {
    tags = {
      project     = var.project
      environment = "shared"
      managed-by  = "terraform"
      owner       = var.owner
    }
  }
}

data "aws_caller_identity" "current" {}

resource "aws_s3_bucket" "tfstate" {
  #checkov:skip=CKV_AWS_144:A single region is enough for this project; cross-region replication of the state bucket would double its cost.
  #checkov:skip=CKV_AWS_145:The bucket uses SSE-S3 (AES256), which is free; a customer-managed KMS key would add cost and key management.
  #checkov:skip=CKV_AWS_18:Access logging needs a second bucket to hold the logs, which is out of scope here.
  #checkov:skip=CKV2_AWS_62:There is no consumer for bucket event notifications.
  bucket = "${var.project}-shared-tfstate-${data.aws_caller_identity.current.account_id}"
  lifecycle { prevent_destroy = true }
}

# Versioning keeps every state file and every lock-file change. Expire the old versions after 90
# days so they do not pile up, and clean up the delete markers the lock file leaves behind.
resource "aws_s3_bucket_lifecycle_configuration" "tfstate" {
  bucket = aws_s3_bucket.tfstate.id

  rule {
    id     = "expire-old-state-versions"
    status = "Enabled"
    filter {}

    noncurrent_version_expiration {
      noncurrent_days = 90
    }
    expiration {
      expired_object_delete_marker = true
    }
    abort_incomplete_multipart_upload {
      days_after_initiation = 7
    }
  }
}

resource "aws_s3_bucket_versioning" "tfstate" {
  bucket = aws_s3_bucket.tfstate.id
  versioning_configuration { status = "Enabled" }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "tfstate" {
  bucket = aws_s3_bucket.tfstate.id
  rule {
    apply_server_side_encryption_by_default { sse_algorithm = "AES256" }
  }
}

resource "aws_s3_bucket_public_access_block" "tfstate" {
  bucket                  = aws_s3_bucket.tfstate.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

data "aws_iam_policy_document" "tfstate_tls_only" {
  statement {
    sid     = "DenyNonTLSRequests"
    effect  = "Deny"
    actions = ["s3:*"]

    principals {
      type        = "*"
      identifiers = ["*"]
    }

    resources = [
      aws_s3_bucket.tfstate.arn,
      "${aws_s3_bucket.tfstate.arn}/*",
    ]

    condition {
      test     = "Bool"
      variable = "aws:SecureTransport"
      values   = ["false"]
    }
  }
}

resource "aws_s3_bucket_policy" "tfstate" {
  bucket = aws_s3_bucket.tfstate.id
  policy = data.aws_iam_policy_document.tfstate_tls_only.json

  depends_on = [aws_s3_bucket_public_access_block.tfstate]
}
resource "aws_iam_openid_connect_provider" "github" {
  url            = "https://token.actions.githubusercontent.com"
  client_id_list = ["sts.amazonaws.com"]
}

# ---------- Pipeline notifications (step 2.6)
# They live here, and not in an environment, for two reasons. Staging is destroyed every day, and an
# e-mail subscription that is recreated has to be confirmed again by clicking a link, so a topic inside
# an environment would stop notifying after every rebuild. And a failed pipeline has to be reported
# when there is no environment at all (a pull request, or a deploy to an environment that is down).

resource "aws_sns_topic" "pipeline_alerts" {
  name = "${var.project}-pipeline-alerts"
  # The AWS-managed key: free, and its key policy lets any principal in this account that may use SNS
  # publish through SNS, so the publisher role below needs no KMS permission (read from the key's policy).
  # It does NOT work for CloudWatch alarms, which cannot be granted use of an AWS-managed key: the alarm
  # topic of the monitoring step needs a customer-managed key, or none.
  kms_master_key_id = "alias/aws/sns"
}

# Terraform cannot confirm an e-mail subscription. AWS sends a message to the address, and the
# subscription stays "PendingConfirmation", and delivers nothing, until someone follows the link in it.
resource "aws_sns_topic_subscription" "pipeline_alerts_email" {
  topic_arn = aws_sns_topic.pipeline_alerts.arn
  protocol  = "email"
  endpoint  = var.alert_email
}

locals {
  github_subject_prefix = "repo:${split("/", var.github_repository)[0]}@${var.github_owner_id}/${split("/", var.github_repository)[1]}@${var.github_repository_id}"
}

# The role the notify jobs of ci.yml and cd.yml assume (OIDC, no stored keys). Unlike the deploy roles it
# belongs to no environment: a notify job has no GitHub Environment. It trusts two token subjects, a run
# on main (cd.yml, and ci.yml started by hand) and a pull request of this repository (ci.yml). A pull
# request from a fork gets no token at all. What it can do is publish to this one topic, so the worst a
# pull request that rewrites the workflow could do with it is send e-mail to the owner.
data "aws_iam_policy_document" "github_notify_trust" {
  statement {
    actions = ["sts:AssumeRoleWithWebIdentity"]
    principals {
      type        = "Federated"
      identifiers = [aws_iam_openid_connect_provider.github.arn]
    }
    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:aud"
      values   = ["sts.amazonaws.com"]
    }
    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:sub"
      values = [
        "${local.github_subject_prefix}:ref:refs/heads/main",
        "${local.github_subject_prefix}:pull_request",
      ]
    }
  }
}

resource "aws_iam_role" "github_notify" {
  name               = "${var.project}-github-notify"
  assume_role_policy = data.aws_iam_policy_document.github_notify_trust.json
}

data "aws_iam_policy_document" "github_notify" {
  statement {
    sid       = "PublishPipelineAlerts"
    actions   = ["sns:Publish"]
    resources = [aws_sns_topic.pipeline_alerts.arn]
  }
}

resource "aws_iam_role_policy" "github_notify" {
  name   = "publish-pipeline-alerts"
  role   = aws_iam_role.github_notify.id
  policy = data.aws_iam_policy_document.github_notify.json
}
