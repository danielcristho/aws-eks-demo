variable "aws_region" {
  description = "The AWS region where the infrastructure will be deployed."
  type        = string
  default     = "ap-southeast-1"
}

variable "cluster_name_prefix" {
  description = "A unique prefix for all created resources"
  type        = string
  default     = "demo"
}

variable "cluster_version" {
  description = "The Kubernetes version for the EKS cluster."
  type        = string
  default     = "1.30"
}

variable "vpc_cidr" {
  description = "The main CIDR block for the VPC."
  type        = string
  default     = "10.1.0.0/21"
}

variable "secondary_cidr_blocks" {
  description = "Secondary CIDR blocks for VPC (used for Pod IPs)."
  type        = list(string)
  default     = ["100.64.0.0/16"]
}

variable "tags" {
  description = "Map of tags to apply to all provisioned AWS resources."
  type        = map(string)
  default     = {}
}