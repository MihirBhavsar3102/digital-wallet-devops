data "aws_caller_identity" "current" {}
data "aws_region" "current" {}

locals {
  account_id = data.aws_caller_identity.current.account_id
  region     = data.aws_region.current.region

  # The subject GitHub puts in the token of a job that runs in the GitHub Environment. Since 15 July
  # 2026 GitHub issues "immutable" subjects to repositories created after that date: the numeric owner
  # and repository ids follow the names (repo:OWNER@OWNER_ID/REPO@REPO_ID:environment:NAME). A trust
  # policy written for the name-only form, repo:OWNER/REPO:environment:NAME, never matches such a
  # token, and AWS answers "Not authorized to perform sts:AssumeRoleWithWebIdentity". The ids also
  # mean that a repository deleted and recreated under the same name cannot assume this role.
  # The SSM parameter that holds the tag of the last release that passed its smoke test. The compute module
  # creates it under this name and reads it at boot, the pipeline writes it. The name is a convention
  # between those places, as the RDS identifier is for the snapshot permission below.
  deployed_tag_parameter_arn = "arn:aws:ssm:${local.region}:${local.account_id}:parameter/${var.name_prefix}/deployed-tag"

  github_owner   = split("/", var.github_repository)[0]
  github_repo    = split("/", var.github_repository)[1]
  github_subject = "repo:${local.github_owner}@${var.github_owner_id}/${local.github_repo}@${var.github_repository_id}:environment:${var.github_environment}"
}

#EC2 instance role 
data "aws_iam_policy_document" "ec2_trust" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["ec2.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "ec2" {
  name               = "${var.name_prefix}-ec2-role"
  assume_role_policy = data.aws_iam_policy_document.ec2_trust.json
}

resource "aws_iam_role_policy_attachment" "ssm" {
  role       = aws_iam_role.ec2.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_iam_role_policy_attachment" "cloudwatch_agent" {
  role       = aws_iam_role.ec2.name
  policy_arn = "arn:aws:iam::aws:policy/CloudWatchAgentServerPolicy"
}

data "aws_iam_policy_document" "ecr_pull" {
  statement {
    sid       = "EcrAuthToken"
    actions   = ["ecr:GetAuthorizationToken"]
    resources = ["*"] # this action does not support resource-level permissions
  }
  statement {
    sid       = "EcrPullFromProjectRepos"
    actions   = ["ecr:BatchGetImage", "ecr:GetDownloadUrlForLayer", "ecr:BatchCheckLayerAvailability"]
    resources = var.ecr_repository_arns
  }
}

resource "aws_iam_role_policy" "ecr_pull" {
  name   = "ecr-pull"
  role   = aws_iam_role.ec2.id
  policy = data.aws_iam_policy_document.ecr_pull.json
}

data "aws_iam_policy_document" "app_secrets" {
  statement {
    sid       = "ReadAppSecrets"
    actions   = ["secretsmanager:GetSecretValue"]
    resources = var.secret_arns # exact ARNs, so only these secrets and nothing else
  }
}

moved {
  from = aws_iam_role_policy.db_secret
  to   = aws_iam_role_policy.app_secrets
}

resource "aws_iam_role_policy" "app_secrets" {
  name   = "read-app-secrets"
  role   = aws_iam_role.ec2.id
  policy = data.aws_iam_policy_document.app_secrets.json
}

# A new instance reads the tag of the last good release at boot (user_data), so that a replacement
# instance converges to it instead of staying on the placeholder.
data "aws_iam_policy_document" "deployed_tag_read" {
  statement {
    sid       = "ReadDeployedTag"
    actions   = ["ssm:GetParameter"]
    resources = [local.deployed_tag_parameter_arn]
  }
}

resource "aws_iam_role_policy" "deployed_tag_read" {
  name   = "read-deployed-tag"
  role   = aws_iam_role.ec2.id
  policy = data.aws_iam_policy_document.deployed_tag_read.json
}

resource "aws_iam_instance_profile" "ec2" {
  name = "${var.name_prefix}-ec2-profile"
  role = aws_iam_role.ec2.name
}

# GitHub Actions deploy role (OIDC)
data "aws_iam_openid_connect_provider" "github" {
  url = "https://token.actions.githubusercontent.com" # created once, in bootstrap
}

data "aws_iam_policy_document" "github_trust" {
  statement {
    actions = ["sts:AssumeRoleWithWebIdentity"]
    principals {
      type        = "Federated"
      identifiers = [data.aws_iam_openid_connect_provider.github.arn]
    }
    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:aud"
      values   = ["sts.amazonaws.com"]
    }
    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:sub"
      values   = [local.github_subject]
    }
  }
}

resource "aws_iam_role" "github_deploy" {
  name               = "${var.name_prefix}-github-deploy"
  assume_role_policy = data.aws_iam_policy_document.github_trust.json
}

data "aws_iam_policy_document" "github_deploy" {
  statement {
    sid       = "EcrAuthToken"
    actions   = ["ecr:GetAuthorizationToken"]
    resources = ["*"]
  }
  statement {
    sid = "EcrPush"
    actions = [
      "ecr:BatchCheckLayerAvailability", "ecr:InitiateLayerUpload",
      "ecr:UploadLayerPart", "ecr:CompleteLayerUpload", "ecr:PutImage",
    ]
    resources = var.ecr_repository_arns
  }
  # Lets the pipeline ask whether a commit's tag is already in a repository, so that a re-run of that
  # commit skips the push (tags are immutable, a second push is rejected). Read-only image metadata.
  statement {
    sid       = "EcrTagExists"
    actions   = ["ecr:DescribeImages"]
    resources = var.ecr_repository_arns
  }
  statement {
    sid       = "RunCommandDocument"
    actions   = ["ssm:SendCommand"]
    resources = ["arn:aws:ssm:${local.region}::document/AWS-RunShellScript"]
  }
  statement {
    sid       = "RunCommandOnThisEnvironmentOnly"
    actions   = ["ssm:SendCommand"]
    resources = ["arn:aws:ec2:${local.region}:${local.account_id}:instance/*"]
    condition {
      test     = "StringEquals"
      variable = "ssm:resourceTag/environment"
      values   = [var.environment]
    }
  }
  # ssm-deploy.sh lists the command's invocations to find the instances it reached, and asks for the
  # command's overall status. These actions do not support resource-level permissions.
  statement {
    sid       = "ReadCommandResult"
    actions   = ["ssm:GetCommandInvocation", "ssm:ListCommandInvocations", "ssm:ListCommands"]
    resources = ["*"]
  }
  statement {
    sid       = "RecordDeployedTag"
    actions   = ["ssm:PutParameter"]
    resources = [local.deployed_tag_parameter_arn]
  }
}

resource "aws_iam_role_policy" "github_deploy" {
  name   = "deploy"
  role   = aws_iam_role.github_deploy.id
  policy = data.aws_iam_policy_document.github_deploy.json
}

data "aws_iam_policy_document" "github_db_snapshot" {
  count = var.allow_db_snapshot ? 1 : 0
  statement {
    sid     = "SnapshotThisEnvironmentDatabase"
    actions = ["rds:CreateDBSnapshot"]
    resources = [
      "arn:aws:rds:${local.region}:${local.account_id}:db:${var.name_prefix}-db",
      "arn:aws:rds:${local.region}:${local.account_id}:snapshot:${var.name_prefix}-*",
    ]
  }
}

resource "aws_iam_role_policy" "github_db_snapshot" {
  count  = var.allow_db_snapshot ? 1 : 0
  name   = "db-snapshot"
  role   = aws_iam_role.github_deploy.id
  policy = data.aws_iam_policy_document.github_db_snapshot[0].json
}
