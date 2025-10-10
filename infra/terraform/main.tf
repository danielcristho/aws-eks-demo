locals {
  name        = var.name
  region      = coalesce(var.aws_region, data.aws_region.current.name)
  account_id  = data.aws_caller_identity.current.account_id
  partition   = data.aws_partition.current.partition

  vpc_cidr = var.vpc_cidr
  azs      = slice(data.aws_availability_zones.available.names, 0, 2)
  private_subnets    = [for k, v in local.azs : cidrsubnet(var.vpc_cidr, 3, k)]
  public_subnets     = [for k, v in local.azs : cidrsubnet(var.vpc_cidr, 5, k + 8)]
  secondary_ip_range = [for k, v in local.azs : cidrsubnet(element(var.secondary_cidr_blocks, 0), 1, k)]

  tags = merge(var.tags, {
    Sample     = var.name
    GithubRepo = "github.com/aws-samples/gen-ai-on-eks"
  })
}

data "aws_region" "current" {}
data "aws_caller_identity" "current" {}
data "aws_availability_zones" "available" {}
data "aws_partition" "current" {}
data "aws_ecrpublic_authorization_token" "token" {
  provider = aws.ecr
}


################################################################################
# Supporting Resources (VPC & EKS Control Plane)
################################################################################
module "vpc" {
  source  = "terraform-aws-modules/vpc/aws"
  version = "~> 5.0"
  # ... (VPC Config lainnya tetap sama dari template)
  name = local.name
  cidr = local.vpc_cidr
  azs  = local.azs
  secondary_cidr_blocks = var.secondary_cidr_blocks
  private_subnets       = concat(local.private_subnets, local.secondary_ip_range)
  public_subnets        = local.public_subnets
  enable_nat_gateway    = true
  single_nat_gateway    = true
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

  # manage_aws_auth_configmap = true

  # aws_auth_roles = [
  #   {
  #     rolearn  = module.eks_blueprints_addons.karpenter.node_iam_role_arn
  #     username = "system:node:{{EC2PrivateDNSName}}"
  #     groups = [
  #       "system:bootstrappers",
  #       "system:nodes",
  #     ]
  #   },
  # ]

  eks_managed_node_groups = {
    core_node_group = {
      name             = "core-node-group"
      ami_type         = "AL2_x86_64"
      min_size         = 1
      max_size         = 2
      desired_size     = 1
      instance_types   = ["t3.medium"]
      labels           = { WorkerType = "ON_DEMAND", NodeGroupType = "core" }
      tags             = merge(local.tags, { Name = "core-node-grp" })
      subnet_ids = compact([for subnet_id, cidr_block in zipmap(module.vpc.private_subnets, module.vpc.private_subnets_cidr_blocks) : substr(cidr_block, 0, 4) == "100." ? subnet_id : null])
    }
    
    gpu1 = {
      name             = "gpu-node-grp-base"
      ami_type         = "AL2_x86_64_GPU"
      min_size         = 0
      max_size         = 1
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
      subnet_ids = compact([for subnet_id, cidr_block in zipmap(module.vpc.private_subnets, module.vpc.private_subnets_cidr_blocks) : substr(cidr_block, 0, 4) == "100." ? subnet_id : null])
    }
  }

  tags = merge(local.tags, { "karpenter.sh/discovery" = local.name })
}

# module "eks_blueprints_addons" {
#   source  = "aws-ia/eks-blueprints-addons/aws"
#   version = "~> 1.16.2"

#   cluster_name      = module.eks.cluster_name
#   cluster_endpoint  = module.eks.cluster_endpoint
#   cluster_version   = module.eks.cluster_version
#   oidc_provider_arn = module.eks.oidc_provider_arn

#   enable_karpenter              = true
#   enable_aws_load_balancer_controller = true
#   enable_ingress_nginx          = true
# }

# resource "aws_eks_config_map" "aws_auth" {
#   cluster_name = module.eks.cluster_id
  
#   map_roles {
#     rolearn  = module.eks_blueprints_addons.karpenter.node_iam_role_arn
#     username = "system:node:{{EC2PrivateDNSName}}"
#     groups   = ["system:bootstrappers", "system:nodes"]
#   }
# }

resource "kubernetes_namespace_v1" "jupyterhub" {
  metadata {
    name = "jupyterhub"
  }
}

module "jupyterhub_single_user_irsa" {
  source  = "terraform-aws-modules/iam/aws//modules/iam-role-for-service-accounts-eks"
  version = "~> 5.30"

  role_name = "jupyterhub-single-user"

  role_policy_arns = {
    policy = "arn:aws:iam::aws:policy/AdministratorAccess" 
  }

  oidc_providers = {
    main = {
      provider_arn           = module.eks.oidc_provider_arn
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

################################################################################
# 2. Multi-Tenancy Resources
################################################################################
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

# resource "aws_auth" "karpenter_node_role" {
#   cluster_name = module.eks.cluster_id

#   map_roles {
#     rolearn  = module.eks_blueprints_addons.karpenter.node_iam_role_arn
#     username = "system:node:{{EC2PrivateDNSName}}"
#     groups   = ["system:bootstrappers", "system:nodes"]
#   }
# }