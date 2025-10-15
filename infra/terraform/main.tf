locals {
  name        = var.cluster_name_prefix
  region      = coalesce(var.aws_region, data.aws_region.current.name)
  account_id  = data.aws_caller_identity.current.account_id
  partition   = data.aws_partition.current.partition

  vpc_cidr = var.vpc_cidr
  # Use 2 Availability Zones for cost efficiency and simple redundancy
  azs      = slice(data.aws_availability_zones.available.names, 0, 2)
  private_subnets    = [for k, v in local.azs : cidrsubnet(var.vpc_cidr, 3, k)]
  public_subnets     = [for k, v in local.azs : cidrsubnet(var.vpc_cidr, 5, k + 8)]
  secondary_ip_range = [for k, v in local.azs : cidrsubnet(element(var.secondary_cidr_blocks, 0), 1, k)]

  tags = merge(var.tags, {
    Project    = "MultiTenantMLPlatform"
    GithubRepo = "github.com/danielcristho/aws-community-day"
  })
}

# Data sources for cluster bootstrapping and IAM
data "aws_region" "current" {}
data "aws_caller_identity" "current" {}
data "aws_availability_zones" "available" {}
data "aws_partition" "current" {}
data "aws_ecrpublic_authorization_token" "token" {
  provider = aws.ecr
}

################################################################################
# VPC & EKS Control Plane
################################################################################
module "vpc" {
  source  = "terraform-aws-modules/vpc/aws"
  version = "~> 5.0"
  name = local.name
  cidr = local.vpc_cidr
  azs  = local.azs
  secondary_cidr_blocks = var.secondary_cidr_blocks
  private_subnets       = concat(local.private_subnets, local.secondary_ip_range)
  public_subnets        = local.public_subnets
  enable_nat_gateway    = true
  single_nat_gateway    = true
  
  # Tags required for AWS Load Balancers and Karpenter discovery
  public_subnet_tags = { "kubernetes.io/role/elb" = 1 }
  private_subnet_tags = {
    "kubernetes.io/role/internal-elb" = 1
    "karpenter.sh/discovery"          = local.name
  }
  tags = local.tags
}

module "eks" {
  source  = "terraform-aws-modules/eks/aws"
  version = "~> 20.0"

  cluster_name                   = local.name
  cluster_version                = var.cluster_version
  cluster_endpoint_public_access = true

  vpc_id     = module.vpc.vpc_id
  subnet_ids = compact([for subnet_id, cidr_block in zipmap(module.vpc.private_subnets, module.vpc.private_subnets_cidr_blocks) : substr(cidr_block, 0, 4) == "100." ? subnet_id : null])

  eks_managed_node_groups = {
    app_head = {
      name             = "app-head-group"
      ami_type         = "AL2_x86_64"
      min_size         = 1
      max_size         = 2
      desired_size     = 1
      instance_types   = ["m5.large"]
      labels           = { WorkerType = "ON_DEMAND", NodeGroupType = "app-head" }
      tags             = merge(local.tags, { Name = "app-head-grp" })
      subnet_ids       = compact([for subnet_id, cidr_block in zipmap(module.vpc.private_subnets, module.vpc.private_subnets_cidr_blocks) : substr(cidr_block, 0, 4) == "100." ? subnet_id : null])
    }
    
    gpu1 = {
      name             = "gpu-node-grp-base"
      ami_type         = "AL2_x86_64_GPU"
      min_size         = 0 # Allows autoscaling from zero
      max_size         = 1 # Budget limit to one GPU instance
      desired_size     = 0 
      instance_types   = ["g4dn.xlarge"]
      labels           = { WorkerType = "ON_DEMAND", NodeGroupType = "gpu" }
      taints = {
        gpu = {
          key      = "nvidia.com/gpu"
          effect   = "NO_SCHEDULE"
          operator = "EXISTS"
        }
      }
      tags             = merge(local.tags, { Name = "gpu-node-grp" })
      subnet_ids       = compact([for subnet_id, cidr_block in zipmap(module.vpc.private_subnets, module.vpc.private_subnets_cidr_blocks) : substr(cidr_block, 0, 4) == "100." ? subnet_id : null])
    }
  }

  tags = merge(local.tags, { "karpenter.sh/discovery" = local.name })
}

################################################################################
# Addons and MLOps Tools (Karpenter, Ingress, Storage)
################################################################################

# Installs Karpenter, ALB Controller, Nginx Ingress
module "eks_blueprints_addons" {
  source  = "aws-ia/eks-blueprints-addons/aws"
  version = "~> 1.16.2"

  cluster_name      = module.eks.cluster_name
  cluster_endpoint  = module.eks.cluster_endpoint
  cluster_version   = module.eks.cluster_version
  oidc_provider_arn = module.eks.oidc_provider_arn

  # IAM Role for EBS CSI Driver (used for storage persistence)
  eks_addons = {
    aws-ebs-csi-driver = {
      service_account_role_arn = module.ebs_csi_driver_irsa.iam_role_arn
    }
    coredns  = { preserve = true }
    kube-proxy = { preserve = true }
    vpc-cni  = { preserve = true }
  }



  # Nginx Ingress Add-on for exposing JupyterHub and Ray Serve
  enable_ingress_nginx          = true
  ingress_nginx = {
    values = [templatefile("${path.module}/helm/nginx-ingress/values.yaml", {})]
  }

  # Karpenter Autoscaler
  enable_karpenter              = true
  karpenter_enable_spot_termination = true # Enable SPOT for max cost savings
  karpenter_node = {
    iam_role_additional_policies = {
      AmazonSSMManagedInstanceCore = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
    }
  }
  karpenter = {
    chart_version       = "0.35.4"
  }

  enable_aws_load_balancer_controller = false
}

# S3 Policy for Karpenter Nodes. Allows Ray Workers to read/write from S3
module "karpenter_policy" {
  source  = "terraform-aws-modules/iam/aws//modules/iam-policy"
  version = "~> 5.20"

  name        = "KarpenterS3AccessPolicy"
  description = "IAM Policy to allow read and write in S3 for Karpenter launched nodes (Ray Workers)"

  policy = jsonencode(
    {
      Version = "2012-10-17"
      Statement = [
        {
          Sid      = "ListObjectsInBucket"
          Effect   = "Allow"
          Action   = ["s3:ListBucket"]
          Resource = ["*"]
        },
        {
          Sid      = "AllObjectActions"
          Effect   = "Allow"
          Action   = "s3:*Object"
          Resource = ["*"]
        }
      ]
    }
  )
}

resource "aws_iam_role_policy_attachment" "karpenter_attach_policy_to_role" {
  role       = element(split("/", module.eks_blueprints_addons.karpenter.node_iam_role_arn), 1)
  policy_arn = module.karpenter_policy.arn
}

resource "aws_s3_bucket" "fm_ops_data" {
  bucket_prefix = "ml-tenant-checkpoints"

  tags = { Name = "datasets-checkpoints" }
}

###############################################################################
# Storage Class for JupyterHub Persistence
################################################################################
resource "kubernetes_annotations" "disable_gp2" {
  annotations = { "storageclass.kubernetes.io/is-default-class" : "false" }
  api_version = "storage.k8s.io/v1"
  kind        = "StorageClass"
  metadata { name = "gp2" }
  force = true
  depends_on = [module.eks.eks_cluster_id]
}

resource "kubernetes_storage_class" "default_gp3" {
  metadata {
    name = "gp3"
    annotations = { "storageclass.kubernetes.io/is-default-class" : "true" }
  }

  storage_provisioner    = "ebs.csi.aws.com"
  reclaim_policy         = "Delete"
  allow_volume_expansion = true
  volume_binding_mode    = "WaitForFirstConsumer"
  parameters = { fsType = "ext4", encrypted = true, type = "gp3" }
  depends_on = [kubernetes_annotations.disable_gp2]
}

################################################################################
# IRSA for EBS CSI Driver
################################################################################
module "ebs_csi_driver_irsa" {
  source                = "terraform-aws-modules/iam/aws//modules/iam-role-for-service-accounts-eks"
  version               = "~> 5.39"
  role_name_prefix      = format("%s-%s-", local.name, "ebs-csi-driver")
  attach_ebs_csi_policy = true
  oidc_providers = {
    main = {
      provider_arn               = module.eks.oidc_provider_arn
      namespace_service_accounts = ["kube-system:ebs-csi-controller-sa"]
    }
  }
  tags = local.tags
}

################################################################################
# 3. Multi-Tenancy & JupyterHub IAM
################################################################################

# Base Namespace for JupyterHub
resource "kubernetes_namespace_v1" "jupyterhub" {
  metadata { name = "jupyterhub" }
}

# IAM Role for Service Account (IRSA) for JupyterHub Single-User Pods (S3 Access)
module "jupyterhub_single_user_irsa" {
  source  = "terraform-aws-modules/iam/aws//modules/iam-role-for-service-accounts-eks"
  version = "~> 5.30"

  role_name = "jupyterhub-single-user"
  role_policy_arns = { policy = "arn:aws:iam::aws:policy/AdministratorAccess" } # Set to minimal permissions later

  oidc_providers = {
    main = {
      provider_arn               = module.eks.oidc_provider_arn
      namespace_service_accounts = ["${kubernetes_namespace_v1.jupyterhub.metadata[0].name}:jupyterhub-single-user"]
    }
  }
}

resource "kubernetes_service_account_v1" "jupyterhub_single_user_sa" {
  metadata {
    name      = "jupyterhub-single-user"
    namespace = kubernetes_namespace_v1.jupyterhub.metadata[0].name
    annotations = { "eks.amazonaws.com/role-arn" : module.jupyterhub_single_user_irsa.iam_role_arn }
  }
}

# Tenant A: High Resource Quota (Training)
resource "kubernetes_namespace_v1" "tenant_a" {
  metadata { name = "tenant-a-mlops" }
}

resource "kubernetes_resource_quota_v1" "quota_tenant_a" {
  metadata {
    name      = "ml-quota-large"
    namespace = kubernetes_namespace_v1.tenant_a.metadata[0].name
  }
  spec {
    hard = {
      "nvidia.com/gpu" = "4"
      "limits.cpu"     = "20"
      "limits.memory"  = "100Gi"
    }
  }
}

# Tenant B: Low Resource Quota (Serving/Testing)
resource "kubernetes_namespace_v1" "tenant_b" {
  metadata { name = "tenant-b-mlops" }
}

resource "kubernetes_resource_quota_v1" "quota_tenant_b" {
  metadata {
    name      = "ml-quota-small"
    namespace = kubernetes_namespace_v1.tenant_b.metadata[0].name
  }
  spec {
    hard = {
      "nvidia.com/gpu" = "1"
      "limits.cpu"     = "5"
      "limits.memory"  = "20Gi"
    }
  }
}

resource "aws_eks_access_entry" "console_admin" {
  cluster_name  = module.eks.cluster_name
  principal_arn = "arn:aws:iam::047719622882:user/salupa"
}

resource "aws_eks_access_policy_association" "console_admin_policy" {
  cluster_name = module.eks.cluster_name
  principal_arn = aws_eks_access_entry.console_admin.principal_arn
  policy_arn = "arn:aws:eks::aws:cluster-access-policy/AmazonEKSClusterAdminPolicy"

  access_scope {
    type = "cluster"
  }
}