variable "name_prefix" {
  type        = string
  description = "Prefix for every resource name, <project>-<environment>."
}
variable "vpc_id" {
  type        = string
  description = "VPC the security groups belong to."
}
variable "alb_ingress_cidrs" {
  type        = list(string)
  description = "CIDR blocks allowed to reach the load balancer on port 80."
  default     = ["0.0.0.0/0"]
  validation {
    condition     = length(var.alb_ingress_cidrs) > 0 && alltrue([for c in var.alb_ingress_cidrs : can(cidrhost(c, 0))])
    error_message = "alb_ingress_cidrs must be a non-empty list of valid IPv4 CIDR blocks."
  }
}
variable "frontend_port" {
  type        = number
  description = "Port the frontend container listens on (nginx in docker-compose)."
  default     = 80
  validation {
    condition     = var.frontend_port >= 1 && var.frontend_port <= 65535
    error_message = "frontend_port must be between 1 and 65535."
  }
}
variable "backend_port" {
  type        = number
  description = "Port the NestJS backend listens on (PORT=8081 in docker-compose)."
  default     = 8081
  validation {
    condition     = var.backend_port >= 1 && var.backend_port <= 65535
    error_message = "backend_port must be between 1 and 65535."
  }
}
variable "db_port" {
  type        = number
  description = "PostgreSQL port."
  default     = 5432
}
