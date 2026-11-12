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

# The CloudWatch agent's configuration, written by hand in monitoring/cloudwatch-agent.json. Terraform only
# fills in the two log group names (templatefile) and stores the result in Parameter Store, where each
# instance fetches it at boot. The agent's own variables are written $${aws:...} in the file so that
# Terraform leaves them for the agent to fill in. scripts/tests/agent-config.test.sh checks the file.
locals {
  agent_config = templatefile("${path.module}/../../../monitoring/cloudwatch-agent.json", {
    syslog_log_group = aws_cloudwatch_log_group.app["syslog"].name
    auth_log_group   = aws_cloudwatch_log_group.app["auth"].name
  })
}

# The name must start with "AmazonCloudWatch-": the AWS-managed CloudWatchAgentServerPolicy on the
# instance role lets the agent read exactly the parameters with that prefix, so no extra permission is
# needed. Keeping the configuration here, and not rendering it into user_data, means a change to it does
# not replace the instances: re-run the agent's fetch-config on them (README, "Changing the agent
# configuration").
resource "aws_ssm_parameter" "agent_config" {
  #checkov:skip=CKV2_AWS_34:An agent configuration is not a secret, so SecureString would only add a key permission to every reader.
  name  = "AmazonCloudWatch-${var.name_prefix}-agent"
  type  = "String"
  value = local.agent_config

  lifecycle {
    precondition {
      condition     = can(jsondecode(local.agent_config))
      error_message = "monitoring/cloudwatch-agent.json is not valid JSON once Terraform has filled it in."
    }
  }
}

resource "aws_cloudwatch_log_group" "app" {
  #checkov:skip=CKV_AWS_158:CloudWatch Logs encrypts at rest by default; a customer-managed KMS key would add cost and key management.
  #checkov:skip=CKV_AWS_338:Retention is a per-environment variable (14 days staging, 90 days prod); one year would cost more than it is worth here.
  for_each          = local.log_groups
  name              = each.value
  retention_in_days = var.log_retention_days
}
