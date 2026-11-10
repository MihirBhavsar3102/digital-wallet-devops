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

# Modules get added here one at a time, bottom-up (network first):
module "network" {
  source             = "../../modules/network"
  name_prefix        = local.name_prefix
  vpc_cidr           = var.vpc_cidr
  single_nat_gateway = true # staging: one shared NAT, cheaper but a single point of failure (see README)
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
  allow_db_snapshot   = false # staging: the deploy role gets no database snapshot permission
}

module "alb" {
  source              = "../../modules/alb"
  name_prefix         = local.name_prefix
  vpc_id              = module.network.vpc_id
  public_subnet_ids   = module.network.public_subnet_ids
  security_group_id   = module.security_groups.alb_security_group_id
  deletion_protection = false # staging: can be destroyed to save money
}

module "compute" {
  source                = "../../modules/compute"
  name_prefix           = local.name_prefix
  subnet_ids            = module.network.private_app_subnet_ids
  security_group_id     = module.security_groups.app_security_group_id
  instance_profile_name = module.iam.instance_profile_name
  instance_type         = "t3.small"
  target_group_arns     = [module.alb.frontend_target_group_arn, module.alb.backend_target_group_arn]
}
