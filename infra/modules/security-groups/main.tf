resource "aws_security_group" "alb" {
  #checkov:skip=CKV2_AWS_5:Checkov scans this module on its own; the group is attached to the load balancer in the alb module.
  name        = "${var.name_prefix}-alb-sg"
  description = "Public entry point: HTTP from the internet to the load balancer"
  vpc_id      = var.vpc_id
  tags        = { Name = "${var.name_prefix}-alb-sg" }
}
resource "aws_security_group" "app" {
  #checkov:skip=CKV2_AWS_5:Checkov scans this module on its own; the group is attached to the instances in the compute module.
  name        = "${var.name_prefix}-app-sg"
  description = "App tier: reachable from the load balancer only, no SSH"
  vpc_id      = var.vpc_id
  tags        = { Name = "${var.name_prefix}-app-sg" }
}
resource "aws_security_group" "db" {
  #checkov:skip=CKV2_AWS_5:Checkov scans this module on its own; the group is attached to the database in the rds module.
  name        = "${var.name_prefix}-db-sg"
  description = "Database tier: PostgreSQL from the app tier only"
  vpc_id      = var.vpc_id
  tags        = { Name = "${var.name_prefix}-db-sg" }
}

# ---- alb
resource "aws_vpc_security_group_ingress_rule" "alb_http" {
  #checkov:skip=CKV_AWS_260:The load balancer is the public entry point, so it is open to the CIDRs in alb_ingress_cidrs (the internet by default).
  for_each          = toset(var.alb_ingress_cidrs)
  security_group_id = aws_security_group.alb.id
  description       = each.value == "0.0.0.0/0" ? "HTTP from the internet" : "HTTP from ${each.value}"
  ip_protocol       = "tcp"
  from_port         = 80
  to_port           = 80
  cidr_ipv4         = each.value
}

# The rule used to be a single resource; this keeps it instead of recreating it.
moved {
  from = aws_vpc_security_group_ingress_rule.alb_http
  to   = aws_vpc_security_group_ingress_rule.alb_http["0.0.0.0/0"]
}
resource "aws_vpc_security_group_egress_rule" "alb_to_app_frontend" {
  security_group_id            = aws_security_group.alb.id
  description                  = "Frontend port to the app tier"
  ip_protocol                  = "tcp"
  from_port                    = var.frontend_port
  to_port                      = var.frontend_port
  referenced_security_group_id = aws_security_group.app.id
}
resource "aws_vpc_security_group_egress_rule" "alb_to_app_backend" {
  security_group_id            = aws_security_group.alb.id
  description                  = "Backend port to the app tier"
  ip_protocol                  = "tcp"
  from_port                    = var.backend_port
  to_port                      = var.backend_port
  referenced_security_group_id = aws_security_group.app.id
}

# ---- app
resource "aws_vpc_security_group_ingress_rule" "app_frontend_from_alb" {
  #checkov:skip=CKV_AWS_260:False positive: the source is the load balancer's security group, not an IP range.
  security_group_id            = aws_security_group.app.id
  description                  = "Frontend port from the load balancer"
  ip_protocol                  = "tcp"
  from_port                    = var.frontend_port
  to_port                      = var.frontend_port
  referenced_security_group_id = aws_security_group.alb.id
}
resource "aws_vpc_security_group_ingress_rule" "app_backend_from_alb" {
  security_group_id            = aws_security_group.app.id
  description                  = "Backend port from the load balancer"
  ip_protocol                  = "tcp"
  from_port                    = var.backend_port
  to_port                      = var.backend_port
  referenced_security_group_id = aws_security_group.alb.id
}
resource "aws_vpc_security_group_egress_rule" "app_https_out" {
  security_group_id = aws_security_group.app.id
  description       = "HTTPS to the internet via NAT (ECR, SSM, CloudWatch, Secrets Manager)"
  ip_protocol       = "tcp"
  from_port         = 443
  to_port           = 443
  cidr_ipv4         = "0.0.0.0/0"
}
resource "aws_vpc_security_group_egress_rule" "app_to_db" {
  security_group_id            = aws_security_group.app.id
  description                  = "PostgreSQL to the database tier"
  ip_protocol                  = "tcp"
  from_port                    = var.db_port
  to_port                      = var.db_port
  referenced_security_group_id = aws_security_group.db.id
}

# ---- db (no egress rule at all: Terraform removes AWS's default allow-all)
resource "aws_vpc_security_group_ingress_rule" "db_from_app" {
  security_group_id            = aws_security_group.db.id
  description                  = "PostgreSQL from the app tier"
  ip_protocol                  = "tcp"
  from_port                    = var.db_port
  to_port                      = var.db_port
  referenced_security_group_id = aws_security_group.app.id
}
