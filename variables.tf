# -----------------------------------------------------------------------------
# Variables for Zero-Downtime EC2 Migration Infrastructure
# -----------------------------------------------------------------------------

variable "region" {
  description = "AWS region to deploy resources in"
  type        = string
}

variable "vpc_cidr" {
  description = "CIDR block for the VPC"
  type        = string
}

variable "subnet_cidr_az1" {
  description = "CIDR block for the first public subnet (AZ1)"
  type        = string
}

variable "subnet_cidr_az2" {
  description = "CIDR block for the second public subnet (AZ2)"
  type        = string
}

variable "ami_id" {
  description = "AMI ID for Amazon Linux 2023"
  type        = string
}

variable "key_name" {
  description = "Name of the EC2 key pair for SSH access"
  type        = string
}

variable "your_ip" {
  description = "Your public IP address in CIDR notation for SSH access (e.g. 203.0.113.10/32)"
  type        = string
}
