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
# module "network" {
#   source      = "../../modules/network"
#   name_prefix = local.name_prefix
#   vpc_cidr    = var.vpc_cidr
# }