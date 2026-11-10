variable "name_prefix" {
  type        = string
  description = "Prefix for every resource name, <project>-<environment>."
}

variable "vpc_cidr" {
  type        = string
  description = "IPv4 CIDR of the VPC, /16 to /19 so every /24-or-larger subnet fits."
  validation {
    condition = try(
      tonumber(split("/", var.vpc_cidr)[1]) >= 16 && tonumber(split("/", var.vpc_cidr)[1]) <= 19,
      false
    )
    error_message = "vpc_cidr must be a valid IPv4 CIDR with a prefix length between /16 and /19."
  }
}

variable "az_count" {
  type        = number
  description = "Number of Availability Zones to use. Each gets a public, a private-app and a private-db subnet."
  default     = 2
  validation {
    condition     = contains([2, 3], var.az_count)
    error_message = "az_count must be 2 or 3."
  }
}

variable "single_nat_gateway" {
  type        = bool
  description = "true: one shared NAT gateway (cheaper, single point of failure). false: one NAT gateway per AZ."
}