# =============================================================================
# Zero-Downtime EC2 Migration Infrastructure
# =============================================================================
#
# Phase 1: Deploy t3.small behind ALB in subnet 1
# Phase 2: Add t3.medium in subnet 2, attach to target group, then remove
#           t3.small for zero-downtime migration
# =============================================================================

# -----------------------------------------------------------------------------
# Terraform & Provider Configuration
# Pin Terraform to >= 1.0 and the AWS provider to ~> 6.0
# -----------------------------------------------------------------------------
terraform {
  required_version = ">= 1.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
  }
}

# Configure the AWS provider with the chosen region
provider "aws" {
  region = var.region
}

# -----------------------------------------------------------------------------
# Data Source — Availability Zones
# Dynamically fetch the available AZs in the selected region so we don't
# hardcode AZ names.
# -----------------------------------------------------------------------------
data "aws_availability_zones" "available" {
  state = "available"
}

# =============================================================================
# NETWORKING
# =============================================================================

# -----------------------------------------------------------------------------
# VPC
# Create a custom VPC with DNS support enabled (required for public DNS
# hostnames on EC2 instances).
# -----------------------------------------------------------------------------
resource "aws_vpc" "main" {
  cidr_block           = var.vpc_cidr
  enable_dns_support   = true
  enable_dns_hostnames = true

  tags = {
    Name = "zero-downtime-vpc"
  }
}

# -----------------------------------------------------------------------------
# Public Subnet — AZ1
# First public subnet; this is where the t3.small (Phase 1) instance lives.
# map_public_ip_on_launch ensures instances get a public IP automatically.
# -----------------------------------------------------------------------------
resource "aws_subnet" "public_az1" {
  vpc_id                  = aws_vpc.main.id
  cidr_block              = var.subnet_cidr_az1
  availability_zone       = data.aws_availability_zones.available.names[0]
  map_public_ip_on_launch = true

  tags = {
    Name = "zero-downtime-public-subnet-az1"
  }
}

# -----------------------------------------------------------------------------
# Public Subnet — AZ2
# Second public subnet in a different AZ; this is where the t3.medium
# (Phase 2) instance will be launched.
# -----------------------------------------------------------------------------
resource "aws_subnet" "public_az2" {
  vpc_id                  = aws_vpc.main.id
  cidr_block              = var.subnet_cidr_az2
  availability_zone       = data.aws_availability_zones.available.names[1]
  map_public_ip_on_launch = true

  tags = {
    Name = "zero-downtime-public-subnet-az2"
  }
}

# -----------------------------------------------------------------------------
# Internet Gateway
# Provides internet access for resources in the public subnets.
# -----------------------------------------------------------------------------
resource "aws_internet_gateway" "main" {
  vpc_id = aws_vpc.main.id

  tags = {
    Name = "zero-downtime-igw"
  }
}

# -----------------------------------------------------------------------------
# Route Table
# A custom route table with a default route (0.0.0.0/0) pointing to the
# Internet Gateway, enabling outbound internet access.
# -----------------------------------------------------------------------------
resource "aws_route_table" "public" {
  vpc_id = aws_vpc.main.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.main.id
  }

  tags = {
    Name = "zero-downtime-public-rt"
  }
}

# -----------------------------------------------------------------------------
# Route Table Association — AZ1
# Explicitly associate the public route table with subnet AZ1.
# -----------------------------------------------------------------------------
resource "aws_route_table_association" "az1" {
  subnet_id      = aws_subnet.public_az1.id
  route_table_id = aws_route_table.public.id
}

# -----------------------------------------------------------------------------
# Route Table Association — AZ2
# Explicitly associate the public route table with subnet AZ2.
# -----------------------------------------------------------------------------
resource "aws_route_table_association" "az2" {
  subnet_id      = aws_subnet.public_az2.id
  route_table_id = aws_route_table.public.id
}

# =============================================================================
# SECURITY GROUPS
# =============================================================================

# -----------------------------------------------------------------------------
# ALB Security Group
# Allows inbound HTTP traffic (port 80) from anywhere. The ALB is the only
# public-facing entry point.
# -----------------------------------------------------------------------------
resource "aws_security_group" "alb" {
  name        = "zero-downtime-alb-sg"
  description = "Allow HTTP inbound traffic to ALB"
  vpc_id      = aws_vpc.main.id

  ingress {
    description = "HTTP from anywhere"
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    description = "Allow all outbound"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "zero-downtime-alb-sg"
  }
}

# -----------------------------------------------------------------------------
# EC2 Security Group
# - Port 80: Only from ALB security group (NOT from 0.0.0.0/0)
# - Port 22: Only from your IP for SSH access
# This ensures EC2 instances are never directly reachable on port 80 from
# the internet — all HTTP traffic must go through the ALB.
# -----------------------------------------------------------------------------
resource "aws_security_group" "ec2" {
  name        = "zero-downtime-ec2-sg"
  description = "Allow HTTP from ALB SG and SSH from my IP"
  vpc_id      = aws_vpc.main.id

  ingress {
    description     = "HTTP from ALB only"
    from_port       = 80
    to_port         = 80
    protocol        = "tcp"
    security_groups = [aws_security_group.alb.id]
  }

  ingress {
    description = "SSH from my IP only"
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = [var.your_ip]
  }

  egress {
    description = "Allow all outbound"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "zero-downtime-ec2-sg"
  }
}

# =============================================================================
# APPLICATION LOAD BALANCER
# =============================================================================

# -----------------------------------------------------------------------------
# Target Group
# Defines how the ALB routes traffic to backend EC2 instances.
# - Health check every 10 seconds with a healthy threshold of 2
# - Deregistration delay set to 30 seconds for fast draining during migration
# - Expects HTTP 200 on "/" to consider the target healthy
# -----------------------------------------------------------------------------
resource "aws_lb_target_group" "main" {
  name                 = "zero-downtime-tg"
  port                 = 80
  protocol             = "HTTP"
  vpc_id               = aws_vpc.main.id
  deregistration_delay = 30

  health_check {
    path                = "/"
    protocol            = "HTTP"
    matcher             = "200"
    interval            = 10
    healthy_threshold   = 2
    unhealthy_threshold = 2
    timeout             = 5
  }

  tags = {
    Name = "zero-downtime-tg"
  }
}

# -----------------------------------------------------------------------------
# Application Load Balancer
# Internet-facing ALB deployed across both public subnets for high
# availability. Uses the ALB security group for inbound rules.
# -----------------------------------------------------------------------------
resource "aws_lb" "main" {
  name               = "zero-downtime-alb"
  internal           = false
  load_balancer_type = "application"
  security_groups    = [aws_security_group.alb.id]
  subnets            = [aws_subnet.public_az1.id, aws_subnet.public_az2.id]

  tags = {
    Name = "zero-downtime-alb"
  }
}

# -----------------------------------------------------------------------------
# ALB Listener
# Listens on port 80 (HTTP) and forwards all traffic to the target group.
# -----------------------------------------------------------------------------
resource "aws_lb_listener" "http" {
  load_balancer_arn = aws_lb.main.arn
  port              = 80
  protocol          = "HTTP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.main.arn
  }

  tags = {
    Name = "zero-downtime-http-listener"
  }
}

# =============================================================================
# EC2 INSTANCES — PHASE 1
# =============================================================================

# -----------------------------------------------------------------------------
# t3.small Instance (Phase 1)
# The original instance running nginx in subnet AZ1. User data installs and
# starts nginx via the user_data.sh script (Amazon Linux 2023 / dnf).
# This is the instance that will be migrated from in Phase 2.
# -----------------------------------------------------------------------------
resource "aws_instance" "t3_small" {
  ami                    = var.ami_id
  instance_type          = "t3.small"
  subnet_id              = aws_subnet.public_az1.id
  vpc_security_group_ids = [aws_security_group.ec2.id]
  key_name               = var.key_name
  user_data              = filebase64("user_data.sh")

  tags = {
    Name = "zero-downtime-t3-small"
  }
}

# -----------------------------------------------------------------------------
# Target Group Attachment — t3.small
# Register the t3.small instance with the ALB target group on port 80.
# -----------------------------------------------------------------------------
resource "aws_lb_target_group_attachment" "t3_small" {
  target_group_arn = aws_lb_target_group.main.arn
  target_id        = aws_instance.t3_small.id
  port             = 80
}

# =============================================================================
# EC2 INSTANCES — PHASE 2 (Uncomment when ready to migrate)
# =============================================================================
#
# Step 1: Uncomment the t3.medium instance and its target group attachment below
# Step 2: Run `terraform apply` — ALB will now route to BOTH instances
# Step 3: Verify both instances are healthy in the target group
# Step 4: Comment out or remove the t3.small instance and its attachment above
# Step 5: Run `terraform apply` again — traffic seamlessly shifts to t3.medium
#
# -----------------------------------------------------------------------------
# t3.medium Instance (Phase 2)
# The new, larger instance in subnet AZ2. Identical configuration to t3.small
# except for instance type and subnet placement.
# -----------------------------------------------------------------------------
# resource "aws_instance" "t3_medium" {
#   ami                    = var.ami_id
#   instance_type          = "t3.medium"
#   subnet_id              = aws_subnet.public_az2.id
#   vpc_security_group_ids = [aws_security_group.ec2.id]
#   key_name               = var.key_name
#   user_data              = filebase64("user_data.sh")
#
#   tags = {
#     Name = "zero-downtime-t3-medium"
#   }
# }

# -----------------------------------------------------------------------------
# Target Group Attachment — t3.medium (Phase 2)
# Register the t3.medium with the same target group so the ALB distributes
# traffic to both instances during the migration window.
# -----------------------------------------------------------------------------
# resource "aws_lb_target_group_attachment" "t3_medium" {
#   target_group_arn = aws_lb_target_group.main.arn
#   target_id        = aws_instance.t3_medium.id
#   port             = 80
# }
