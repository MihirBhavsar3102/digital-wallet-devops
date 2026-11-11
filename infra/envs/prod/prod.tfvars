# Production: the resilient layout. Everything not set here uses the default in variables.tf, and
# staging's values are in staging.tfvars. The Terraform code is the same for both.
#
# This file is committed on purpose. It holds no secrets: the database password is created by RDS
# and the JWT secret by Terraform, neither is ever a variable. Personal or secret values belong in
# a local.tfvars file, which git ignores.

environment = "prod"
aws_region  = "ap-south-1"
owner       = "MihirBhavsar3102"

# network
vpc_cidr           = "10.20.0.0/16"
single_nat_gateway = false # one NAT gateway per AZ, so one AZ failing does not cut outbound access

# compute
instance_type        = "t3.small"
asg_min_size         = 2
asg_desired_capacity = 2
asg_max_size         = 3

# load balancer
backend_health_check_path = "/api/health" # the real app's public route; the first-boot placeholder answers it too

# database
db_instance_class          = "db.t4g.micro"
db_multi_az                = true
db_backup_retention_period = 7

# protection and retention
deletion_protection = true # also: a final snapshot is taken, the access log bucket and ECR images are kept
allow_db_snapshot   = true
log_retention_days  = 90

# deploy pipeline
github_environment       = "production"             # the GitHub Environment's name (the approval gate); the Terraform environment is prod
image_source_name_prefix = "digital-wallet-staging" # production promotes the image that passed staging and does not build its own
