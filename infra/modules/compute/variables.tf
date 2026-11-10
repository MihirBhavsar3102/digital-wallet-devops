variable "name_prefix" {
  type        = string
  description = "Prefix for every resource name, <project>-<environment>."
}

variable "subnet_ids" {
  type        = list(string)
  description = "Private-app subnet IDs, one per AZ, that the Auto Scaling group launches into."
}

variable "security_group_id" {
  type        = string
  description = "ID of the app tier security group."
}

variable "instance_profile_name" {
  type        = string
  description = "Name of the instance profile to attach to the instances."
}

variable "instance_type" {
  type        = string
  description = "EC2 instance type. Must be x86_64 because the AMI is amd64, so Graviton types such as t4g are rejected."
  default     = "t3.small"
  validation {
    condition     = can(regex("^[a-z]+[0-9]+[a-z]*\\.[a-z0-9]+$", var.instance_type)) && !can(regex("^[a-z]+[0-9]+g", var.instance_type))
    error_message = "instance_type must look like t3.small and be an x86_64 family (no Graviton types such as t4g or m7g)."
  }
}

variable "root_volume_size" {
  type        = number
  description = "Root volume size in GiB."
  default     = 20
}

variable "min_size" {
  type        = number
  description = "Minimum number of instances."
  default     = 1
}

variable "desired_capacity" {
  type        = number
  description = "Desired number of instances."
  default     = 2
  validation {
    condition     = var.desired_capacity >= var.min_size && var.desired_capacity <= var.max_size
    error_message = "desired_capacity must be between min_size and max_size."
  }
}

variable "max_size" {
  type        = number
  description = "Maximum number of instances."
  default     = 3
}

variable "health_check_grace_period" {
  type        = number
  description = "Seconds the Auto Scaling group ignores load balancer health checks after launch, to cover the user_data install."
  default     = 300
}

variable "target_group_arns" {
  type        = list(string)
  description = "Target groups to register instances with. Empty until the load balancer exists."
  default     = []
}
