module "vpc" {
  source  = "terraform-aws-modules/vpc/aws"
  version = "~> 5.0"

  name = "${var.cluster_name}-vpc"
  cidr = var.vpc_cidr

  azs             = ["${var.region}a", "${var.region}b"]
  public_subnets  = ["10.0.1.0/24", "10.0.2.0/24"]
  private_subnets = ["10.0.10.0/24", "10.0.11.0/24"]

  enable_nat_gateway = true
  single_nat_gateway = true
}

# Module EKS (Control Plane)
module "eks" {
  source  = "terraform-aws-modules/eks/aws"
  version = "~> 20.0"

  cluster_name    = var.cluster_name
  cluster_version = "1.28" # Versi yang sudah Anda coba
  vpc_id          = module.vpc.vpc_id
  subnet_ids      = module.vpc.private_subnets
  
  # PENTING: Aktifkan OIDC untuk IRSA/Pod Identity
  cluster_addons = {
    coredns = {}
    kube-proxy = {}
    vpc-cni = {
      resolve_conflicts = "OVERWRITE"
    }
  }

  # PENTING: Aktifkan OIDC untuk IRSA
  enable_cluster_creator_auth = true
  iam_role_additional_policies = {
    # Tambahkan kebijakan yang dibutuhkan Karpenter, dll. di sini
  }
}