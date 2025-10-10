# variables.tf
variable "aws_region" {
  description = "AWS Region."
  type        = string
  default     = "ap-southeast-1"
}

variable "vpc_cidr" {
  description = "VPC CIDR. This should be a valid private (RFC 1918) CIDR range"
  default     = "10.1.0.0/21"
  type        = string
}

variable "secondary_cidr_blocks" {
  description = "Secondary CIDR blocks to be attached to VPC"
  default     = ["100.64.0.0/16"]
  type        = list(string)
}

variable "name" {
  description = "Name to be added to the modules and resources."
  type        = string
  default     = "ml-tenant-eks"
}

variable "cluster_version" {
  description = "Amazon EKS Cluster version."
  type        = string
  default     = "1.28"
}

variable "huggingface_token" {
  description = "Hugging Face Secret Token"
  type        = string
  default     = "DUMMY_VALUE"
  sensitive   = true
}

variable "tags" {
  type        = map(string)
  description = "AWS tags"
  default     = {}
}