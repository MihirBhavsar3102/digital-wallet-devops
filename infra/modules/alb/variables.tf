variable "name_prefix" {
  type        = string
  description = "Prefix for every resource name, <project>-<environment>."
}

variable "vpc_id" {
  type        = string
  description = "VPC the target groups belong to."
}

variable "public_subnet_ids" {
  type        = list(string)
  description = "Public subnet IDs, one per AZ, for the load balancer."
}

variable "security_group_id" {
  type        = string
  description = "ID of the load balancer security group."
}

variable "deletion_protection" {
  type        = bool
  description = "Block deletion of the load balancer through the API. On in production. Also decides whether the access log bucket can be force-destroyed."
}

variable "frontend_port" {
  type        = number
  description = "Port the frontend listens on. Keep in sync with the security-groups module."
  default     = 80
}

variable "backend_port" {
  type        = number
  description = "Port the backend listens on (PORT=8081 in the upstream compose file). Keep in sync with the security-groups module."
  default     = 8081
}

variable "frontend_health_check_path" {
  type        = string
  description = "Health check path for the frontend target group."
  default     = "/"
}

variable "backend_health_check_path" {
  type        = string
  description = "Health check path for the backend target group. /api is the existing route; switch to /api/health once the app has one."
  default     = "/api"
}

variable "deregistration_delay" {
  type        = number
  description = "Seconds to drain a target before it is removed."
  default     = 30
}

variable "access_log_retention_days" {
  type        = number
  description = "Days before load balancer access logs expire."
  default     = 30
}
