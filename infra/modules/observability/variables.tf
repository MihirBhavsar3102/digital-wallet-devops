variable "name_prefix" {
  type        = string
  description = "Prefix for every resource name, for example digital-wallet-staging."
}

# ---------- what the dashboards and alarms look at ----------
# This module is called after the compute, load balancer, database and monitoring modules, and only reads from
# them. It is a module of its own, and not part of "monitoring", because monitoring is an input of compute (the
# log group names go into the instances' boot script): a monitoring module that also needed compute's outputs
# would make the two refer to each other. Terraform copes with that, but checkov did not: it silently stopped
# evaluating an IAM policy document in the environments, so the cycle weakened a gate without failing it.
variable "autoscaling_group_name" {
  type        = string
  description = "Name of the Auto Scaling group that runs the app instances: the dimension of the instance metrics."
}

variable "alb_arn_suffix" {
  type        = string
  description = "ARN suffix of the load balancer (app/<name>/<id>): the LoadBalancer dimension of the AWS/ApplicationELB metrics."
}

variable "frontend_target_group_arn_suffix" {
  type        = string
  description = "ARN suffix of the frontend target group (targetgroup/<name>/<id>): the TargetGroup dimension."
}

variable "backend_target_group_arn_suffix" {
  type        = string
  description = "ARN suffix of the backend (API) target group (targetgroup/<name>/<id>): the TargetGroup dimension."
}

variable "db_instance_identifier" {
  type        = string
  description = "Identifier of the database instance: the DBInstanceIdentifier dimension of the AWS/RDS metrics."
}

variable "alarm_topic_arn" {
  type        = string
  description = "ARN of the SNS topic the alarms notify. It lives in infra/bootstrap, and not in an environment, because an e-mail subscription has to be confirmed by a click and an environment is rebuilt every day."
  validation {
    condition     = can(regex("^arn:aws:sns:", var.alarm_topic_arn))
    error_message = "alarm_topic_arn must be the ARN of an SNS topic."
  }
}

variable "log_group_names" {
  type        = map(string)
  description = "Names of the application and system log groups from the monitoring module, keyed by kind. This module needs backend and auth."
  validation {
    condition     = alltrue([for kind in ["backend", "auth"] : contains(keys(var.log_group_names), kind)])
    error_message = "log_group_names must contain the keys backend and auth."
  }
}

variable "application_errors_metric" {
  type = object({
    namespace = string
    name      = string
  })
  description = "Namespace and name of the custom metric that counts application error log lines (monitoring module output)."
}

# One set of numbers, used twice: the alarms fire at these values, and the dashboards draw them as a horizontal
# line on the panel, so a threshold on a graph is always the real one. They are starting points; tune them
# once there is a baseline (the p95 latency in particular is a placeholder until the load test of step 3.8).
variable "alarm_thresholds" {
  type = object({
    cpu_percent            = optional(number, 80)
    memory_percent         = optional(number, 85)
    disk_percent           = optional(number, 80)
    error_rate_percent     = optional(number, 5)
    p95_latency_seconds    = optional(number, 1)
    application_errors     = optional(number, 1)
    rds_cpu_percent        = optional(number, 80)
    rds_free_storage_bytes = optional(number, 2147483648) # 2 GiB
  })
  description = "Alarm thresholds, which the dashboards also draw. Any attribute left out keeps its default."
  default     = {}
}
