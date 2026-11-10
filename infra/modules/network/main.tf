data "aws_availability_zones" "available" {
  state = "available"
  filter {
    name   = "opt-in-status"
    values = ["opt-in-not-required"] # skips Local Zones and Wavelength
  }
}

locals {
  az_count = 2
  azs      = slice(data.aws_availability_zones.available.names, 0, local.az_count)

  public_cidrs      = [for i in range(local.az_count) : cidrsubnet(var.vpc_cidr, 8, i)]
  private_app_cidrs = [for i in range(local.az_count) : cidrsubnet(var.vpc_cidr, 8, i + 10)]
  private_db_cidrs  = [for i in range(local.az_count) : cidrsubnet(var.vpc_cidr, 8, i + 20)]

  nat_count = var.single_nat_gateway ? 1 : local.az_count
}

resource "aws_vpc" "this" {
  cidr_block           = var.vpc_cidr
  enable_dns_support   = true
  enable_dns_hostnames = true
  tags                 = { Name = "${var.name_prefix}-vpc" }
}

resource "aws_subnet" "public" {
  count             = local.az_count
  vpc_id            = aws_vpc.this.id
  cidr_block        = local.public_cidrs[count.index]
  availability_zone = local.azs[count.index]
  tags              = { Name = "${var.name_prefix}-public-${local.azs[count.index]}" }
}

resource "aws_subnet" "private_app" {
  count             = local.az_count
  vpc_id            = aws_vpc.this.id
  cidr_block        = local.private_app_cidrs[count.index]
  availability_zone = local.azs[count.index]
  tags              = { Name = "${var.name_prefix}-private-app-${local.azs[count.index]}" }
}

resource "aws_subnet" "private_db" {
  count             = local.az_count
  vpc_id            = aws_vpc.this.id
  cidr_block        = local.private_db_cidrs[count.index]
  availability_zone = local.azs[count.index]
  tags              = { Name = "${var.name_prefix}-private-db-${local.azs[count.index]}" }
}

resource "aws_internet_gateway" "this" {
  vpc_id = aws_vpc.this.id
  tags   = { Name = "${var.name_prefix}-igw" }
}

resource "aws_route_table" "public" {
  vpc_id = aws_vpc.this.id
  tags   = { Name = "${var.name_prefix}-public-rt" }
}

resource "aws_route" "public_internet" {
  route_table_id         = aws_route_table.public.id
  destination_cidr_block = "0.0.0.0/0"
  gateway_id             = aws_internet_gateway.this.id
}

resource "aws_route_table_association" "public" {
  count          = local.az_count
  subnet_id      = aws_subnet.public[count.index].id
  route_table_id = aws_route_table.public.id
}

resource "aws_eip" "nat" {
  count      = local.nat_count
  domain     = "vpc"
  depends_on = [aws_internet_gateway.this]
  tags       = { Name = "${var.name_prefix}-nat-eip-${count.index + 1}" }
}

resource "aws_nat_gateway" "this" {
  count         = local.nat_count
  allocation_id = aws_eip.nat[count.index].id
  subnet_id     = aws_subnet.public[count.index].id # NAT lives in a PUBLIC subnet
  depends_on    = [aws_internet_gateway.this]
  tags          = { Name = "${var.name_prefix}-nat-${local.azs[count.index]}" }
}