# Staging: the cheaper layout. Everything not set here uses the default in variables.tf, and
# production's values are in prod.tfvars. The Terraform code is the same for both.
#
# This file is committed on purpose. It holds no secrets: the database password is created by RDS
# and the JWT secret by Terraform, neither is ever a variable. Personal or secret values belong in
# a local.tfvars file, which git ignores.

environment = "staging"
aws_region  = "ap-south-1"
owner       = "MihirBhavsar3102"

# network
vpc_cidr           = "10.10.0.0/16"
single_nat_gateway = true # one shared NAT gateway: cheaper, but a single point of failure

# compute
instance_type        = "t3.small"
asg_min_size         = 1
asg_desired_capacity = 1
asg_max_size         = 2

# database
db_instance_class          = "db.t4g.micro"
db_multi_az                = false
db_backup_retention_period = 1

# protection and retention
deletion_protection = false # also: no final snapshot, access log bucket can be emptied on destroy
allow_db_snapshot   = false
log_retention_days  = 14
