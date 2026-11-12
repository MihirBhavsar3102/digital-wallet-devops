# Log groups for the application and the hosts. Terraform creates them, with a retention period,
# before anything writes to them. A group that is left to be created on the first write (by the
# CloudWatch agent or by Docker's awslogs driver) never expires and keeps costing money for as long
# as the account exists. The database's own groups are created, with the same retention, in the rds
# module, because they have to exist before the instance that exports to them.
locals {
  log_groups = {
    backend  = "/${var.name_prefix}/backend"  # backend container output: one JSON object per line
    frontend = "/${var.name_prefix}/frontend" # nginx container: JSON access log and the error log
    syslog   = "/${var.name_prefix}/syslog"   # /var/log/syslog of the instances
    auth     = "/${var.name_prefix}/auth"     # /var/log/auth.log of the instances
  }
}

resource "aws_cloudwatch_log_group" "app" {
  #checkov:skip=CKV_AWS_158:CloudWatch Logs encrypts at rest by default; a customer-managed KMS key would add cost and key management.
  #checkov:skip=CKV_AWS_338:Retention is a per-environment variable (14 days staging, 90 days prod); one year would cost more than it is worth here.
  for_each          = local.log_groups
  name              = each.value
  retention_in_days = var.log_retention_days
}
