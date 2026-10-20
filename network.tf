data "aws_availability_zones" "available" {
  state = "available"
}

# Two availability zones because an RDS subnet group needs subnets in at least two.
# No NAT gateway: the Beanstalk instance sits in a public subnet with its own Elastic IP,
# and the database never needs to reach the internet.
module "vpc" {
  source  = "terraform-aws-modules/vpc/aws"
  version = "6.7.3"

  name = local.name
  cidr = "10.0.0.0/16"

  azs             = slice(data.aws_availability_zones.available.names, 0, 2)
  public_subnets  = ["10.0.0.0/24", "10.0.1.0/24"]
  private_subnets = ["10.0.10.0/24", "10.0.11.0/24"]

  enable_nat_gateway      = false
  map_public_ip_on_launch = true
  enable_dns_hostnames    = true
  enable_dns_support      = true
}

# AWS-maintained list of the addresses CloudFront uses to reach origins
data "aws_ec2_managed_prefix_list" "cloudfront_origin_facing" {
  name = "com.amazonaws.global.cloudfront.origin-facing"
}

resource "aws_security_group" "backend" {
  name        = "${local.name}-backend"
  description = "Beanstalk instance: HTTP from CloudFront only"
  vpc_id      = module.vpc.vpc_id

  tags = {
    Name = "${local.name}-backend"
  }
}

# The list weighs 55 of the 60 rules a security group allows, so it fits only once
resource "aws_vpc_security_group_ingress_rule" "backend_http_from_cloudfront" {
  security_group_id = aws_security_group.backend.id
  description       = "HTTP from CloudFront"
  ip_protocol       = "tcp"
  from_port         = 80
  to_port           = 80
  prefix_list_id    = data.aws_ec2_managed_prefix_list.cloudfront_origin_facing.id
}

resource "aws_vpc_security_group_egress_rule" "backend_all" {
  security_group_id = aws_security_group.backend.id
  description       = "AWS APIs, OS packages, Cognito signing keys and the database"
  ip_protocol       = "-1"
  cidr_ipv4         = "0.0.0.0/0"
}

resource "aws_security_group" "database" {
  name        = "${local.name}-db"
  description = "RDS PostgreSQL: 5432 from the Beanstalk instance only"
  vpc_id      = module.vpc.vpc_id

  tags = {
    Name = "${local.name}-db"
  }
}

resource "aws_vpc_security_group_ingress_rule" "database_from_backend" {
  security_group_id            = aws_security_group.database.id
  description                  = "PostgreSQL from the Beanstalk instance"
  ip_protocol                  = "tcp"
  from_port                    = 5432
  to_port                      = 5432
  referenced_security_group_id = aws_security_group.backend.id
}
