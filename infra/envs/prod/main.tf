provider "aws" {
  region = var.aws_region
  default_tags {
    tags = {
      project     = var.project
      environment = var.environment
      managed-by  = "terraform"
      owner       = var.owner
    }
  }
}

locals {
  name_prefix = "${var.project}-${var.environment}"
}

# Smoke test: proves credentials + backend work. Delete once real modules exist.
data "aws_caller_identity" "current" {}

module "network" {
  source             = "../../modules/network"
  name_prefix        = local.name_prefix
  vpc_cidr           = var.vpc_cidr
  single_nat_gateway = false # prod: one NAT gateway per AZ, so one AZ failing doesn't cut outbound access
}

module "security_groups" {
  source      = "../../modules/security-groups"
  name_prefix = local.name_prefix
  vpc_id      = module.network.vpc_id
}

module "ecr" {
  source      = "../../modules/ecr"
  name_prefix = local.name_prefix
}

module "iam" {
  source              = "../../modules/iam"
  name_prefix         = local.name_prefix
  environment         = var.environment
  github_repository   = var.github_repository
  github_environment  = var.environment # the GitHub Environment must have exactly this name
  ecr_repository_arns = values(module.ecr.repository_arns)
  db_secret_name      = "${local.name_prefix}-db-credentials"
  allow_db_snapshot   = true # prod: the deploy role may snapshot the database before a deploy
}

