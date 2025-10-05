variable "region" {
  description = "AWS region for the deployment"
  default     = "ap-southeast-1"
}

variable "cluster_name" {
  description = "Name of the EKS cluster"
  default     = "ml-ray-jhub-demo"
}

variable "vpc_cidr" {
  description = "VPC CIDR block"
  default     = "10.0.0.0/16"
}

variable "bucket_name_prefix" {
  description = "Prefix for the S3 bucket name"
  default     = "ml-artifacts-ray-demo"
}