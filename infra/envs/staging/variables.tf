variable "project" {
  type        = string
  description = "Project name, first part of every resource name."
  default     = "digital-wallet"
  validation {
    condition     = can(regex("^[a-z][a-z0-9-]{1,23}$", var.project))
    error_message = "project must be 2-24 chars: lowercase letters, digits, hyphens, starting with a letter."
  }
}

variable "environment" {
  type        = string
  description = "Deployment environment: staging or prod."
  validation {
    condition     = contains(["staging", "prod"], var.environment)
    error_message = "environment must be \"staging\" or \"prod\"."
  }
}

variable "aws_region" {
  type        = string
  description = "AWS region to deploy into."
  validation {
    condition     = can(regex("^[a-z]{2}(-[a-z]+)+-[0-9]+$", var.aws_region))
    error_message = "aws_region must look like us-east-1 or ap-south-1."
  }
}

variable "owner" {
  type        = string
  description = "Person or team responsible, written to the owner tag."
  validation {
    condition     = length(trimspace(var.owner)) > 0
    error_message = "owner must not be empty."
  }
}

variable "extra_tags" {
  type        = map(string)
  description = "Extra tags added to every resource, for example a cost centre. The four standard tags (project, environment, managed-by, owner) cannot be overridden."
  default     = {}
  validation {
    condition     = alltrue([for k in keys(var.extra_tags) : !contains(["project", "environment", "managed-by", "owner"], k)])
    error_message = "extra_tags must not contain project, environment, managed-by or owner."
  }
}

variable "github_repository" {
  type        = string
  description = "GitHub repository allowed to deploy to this environment, as OWNER/REPO. Not secret, so it has a default and CI needs no tfvars file."
  default     = "MihirBhavsar3102/digital-wallet-devops"
  validation {
    condition     = can(regex("^[A-Za-z0-9-]+/[A-Za-z0-9._-]+$", var.github_repository))
    error_message = "github_repository must look like OWNER/REPO."
  }
}

# ---------- network ----------
variable "vpc_cidr" {
  type        = string
  description = "IPv4 CIDR block for the VPC, e.g. 10.10.0.0/16."
  validation {
    condition     = can(cidrhost(var.vpc_cidr, 0)) && can(regex("^[0-9.]+/[0-9]+$", var.vpc_cidr))
    error_message = "vpc_cidr must be a valid IPv4 CIDR such as 10.10.0.0/16."
  }
}

variable "az_count" {
  type        = number
  description = "Number of Availability Zones to use (2 or 3)."
  default     = 2
  validation {
    condition     = contains([2, 3], var.az_count)
    error_message = "az_count must be 2 or 3."
  }
}

variable "single_nat_gateway" {
  type        = bool
  description = "true: one shared NAT gateway (cheaper, single point of failure; staging). false: one NAT gateway per AZ (production)."
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

# ---------- application ----------
variable "frontend_port" {
  type        = number
  description = "Port the frontend listens on. Used by the security groups, the load balancer and the instance placeholder."
  default     = 80
  validation {
    condition     = var.frontend_port >= 1 && var.frontend_port <= 65535
    error_message = "frontend_port must be between 1 and 65535."
  }
}

variable "backend_port" {
  type        = number
  description = "Port the backend listens on (PORT=8081 in the upstream compose file). Used by the security groups, the load balancer and the instance placeholder."
  default     = 8081
  validation {
    condition     = var.backend_port >= 1 && var.backend_port <= 65535 && var.backend_port != var.frontend_port
    error_message = "backend_port must be between 1 and 65535 and different from frontend_port."
  }
}

variable "frontend_health_check_path" {
  type        = string
  description = "Load balancer health check path for the frontend."
  default     = "/"
  validation {
    condition     = startswith(var.frontend_health_check_path, "/")
    error_message = "frontend_health_check_path must start with /."
  }
}

variable "backend_health_check_path" {
  type        = string
  description = "Load balancer health check path for the backend. /api is the existing route; use /api/health once the app has one."
  default     = "/api"
  validation {
    condition     = startswith(var.backend_health_check_path, "/")
    error_message = "backend_health_check_path must start with /."
  }
}

# ---------- compute ----------
variable "instance_type" {
  type        = string
  description = "EC2 instance type for the app instances. Must be x86_64 (the AMI is amd64), so Graviton types such as t4g are rejected."
  default     = "t3.small"
  validation {
    condition     = can(regex("^[a-z]+[0-9]+[a-z]*\\.[a-z0-9]+$", var.instance_type)) && !can(regex("^[a-z]+[0-9]+g", var.instance_type))
    error_message = "instance_type must look like t3.small and be an x86_64 family (no Graviton types such as t4g or m7g)."
  }
}

variable "asg_min_size" {
  type        = number
  description = "Minimum number of app instances."
  validation {
    condition     = var.asg_min_size >= 1
    error_message = "asg_min_size must be at least 1."
  }
}

variable "asg_desired_capacity" {
  type        = number
  description = "Desired number of app instances."
  validation {
    condition     = var.asg_desired_capacity >= var.asg_min_size && var.asg_desired_capacity <= var.asg_max_size
    error_message = "asg_desired_capacity must be between asg_min_size and asg_max_size."
  }
}

variable "asg_max_size" {
  type        = number
  description = "Maximum number of app instances."
  validation {
    condition     = var.asg_max_size >= var.asg_min_size
    error_message = "asg_max_size must be at least asg_min_size."
  }
}

# ---------- database ----------
variable "db_name" {
  type        = string
  description = "Name of the initial database."
  default     = "digital_wallet"
  validation {
    condition     = can(regex("^[a-z][a-z0-9_]{0,62}$", var.db_name))
    error_message = "db_name must start with a lowercase letter and use only lowercase letters, digits and underscores."
  }
}

variable "db_instance_class" {
  type        = string
  description = "RDS instance class, for example db.t4g.micro."
  default     = "db.t4g.micro"
  validation {
    condition     = can(regex("^db\\.[a-z0-9]+\\.[a-z0-9]+$", var.db_instance_class))
    error_message = "db_instance_class must look like db.t4g.micro."
  }
}

variable "db_allocated_storage" {
  type        = number
  description = "Database storage in GiB (gp3). 20 is the minimum."
  default     = 20
  validation {
    condition     = var.db_allocated_storage >= 20 && var.db_allocated_storage <= 65536
    error_message = "db_allocated_storage must be between 20 and 65536 GiB."
  }
}

variable "db_engine_version" {
  type        = string
  description = "PostgreSQL version. A major-only value such as 17 lets AWS apply minor upgrades."
  default     = "17"
  validation {
    condition     = can(regex("^[0-9]+(\\.[0-9]+)?$", var.db_engine_version))
    error_message = "db_engine_version must look like 17 or 17.11."
  }
}

variable "db_multi_az" {
  type        = bool
  description = "Run a standby database in a second AZ. false in staging, true in production."
}

variable "db_backup_retention_period" {
  type        = number
  description = "Days to keep automated database backups. 1 in staging, 7 in production."
  validation {
    condition     = var.db_backup_retention_period >= 0 && var.db_backup_retention_period <= 35
    error_message = "db_backup_retention_period must be between 0 and 35."
  }
}

# ---------- protection and retention ----------
variable "deletion_protection" {
  type        = bool
  description = "true (production): the database and load balancer cannot be deleted by accident, the database takes a final snapshot, the access log bucket and the images in the ECR repositories are kept and secrets keep a recovery window. false (staging): all of that is off so the environment can be destroyed cleanly."
}

variable "allow_db_snapshot" {
  type        = bool
  description = "Let the GitHub deploy role create a database snapshot before a deploy. true in production only."
}

variable "log_retention_days" {
  type        = number
  description = "Days to keep logs: the database's CloudWatch log groups and the load balancer access logs."
  validation {
    condition     = contains([1, 3, 5, 7, 14, 30, 60, 90, 120, 150, 180, 365, 400, 545, 731, 1096, 1827, 2192, 2557, 2922, 3288, 3653], var.log_retention_days)
    error_message = "log_retention_days must be a value CloudWatch Logs accepts, for example 7, 14, 30 or 90."
  }
}

# There is deliberately no database password variable: RDS creates and rotates the master
# password in Secrets Manager (see modules/rds), and the JWT secret is generated by Terraform
# without ever being stored in state (see modules/secrets). Any variable that does hold a secret
# must be declared with sensitive = true.
