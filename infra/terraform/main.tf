locals {
  name        = var.cluster_name_prefix
  region      = coalesce(var.aws_region, data.aws_region.current.name)
  account_id  = data.aws_caller_identity.current.account_id
  partition   = data.aws_partition.current.partition

  vpc_cidr = var.vpc_cidr
  azs      = slice(data.aws_availability_zones.available.names, 0, 2)

  private_subnets    = [for k, v in local.azs : cidrsubnet(var.vpc_cidr, 3, k)]
  public_subnets     = [for k, v in local.azs : cidrsubnet(var.vpc_cidr, 5, k + 8)]
  secondary_ip_range = [for k, v in local.azs : cidrsubnet(element(var.secondary_cidr_blocks, 0), 1, k)]

  tags = merge(var.tags, {
    Project    = "MultiTenantMLPlatform"
    GithubRepo = "github.com/danielcristho/aws-community-day"
  })
}

data "aws_region" "current" {}
data "aws_caller_identity" "current" {}
data "aws_availability_zones" "available" {}
data "aws_partition" "current" {}

################################################################################
# VPC MODULE
################################################################################
module "vpc" {
  source  = "terraform-aws-modules/vpc/aws"
  version = "~> 5.0"

  name               = local.name
  cidr               = local.vpc_cidr
  azs                = local.azs
  secondary_cidr_blocks = var.secondary_cidr_blocks
  private_subnets       = concat(local.private_subnets, local.secondary_ip_range)
  public_subnets        = local.public_subnets

  enable_nat_gateway = true
  single_nat_gateway = true

  public_subnet_tags = { "kubernetes.io/role/elb" = 1 }
  private_subnet_tags = {
    "kubernetes.io/role/internal-elb" = 1
    "karpenter.sh/discovery"          = local.name
  }

  tags = local.tags
}

################################################################################
# EKS CLUSTER & NODEGROUPS
################################################################################
module "eks" {
  source  = "terraform-aws-modules/eks/aws"
  version = "~> 20.0"

  cluster_name                   = local.name
  cluster_version                = var.cluster_version
  cluster_endpoint_public_access = true

  vpc_id     = module.vpc.vpc_id
  subnet_ids = compact([
    for subnet_id, cidr_block in zipmap(module.vpc.private_subnets, module.vpc.private_subnets_cidr_blocks) :
    substr(cidr_block, 0, 4) == "100." ? subnet_id : null
  ])

  eks_managed_node_group_defaults = {
    iam_role_additional_policies = {
      AmazonSSMManagedInstanceCore = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
    }
    ebs_optimized = true
    block_device_mappings = {
      xvda = {
        device_name = "/dev/xvda"
        ebs = {
          volume_size = 100
          volume_type = "gp3"
          encrypted   = true
        }
      }
    }
  }

  eks_managed_node_groups = {
    head = {
      name             = "head-group"
      ami_type         = "AL2_x86_64"
      instance_types   = ["m5.large"]
      min_size         = 1
      max_size         = 2
      desired_size     = 1
      labels           = { WorkerType = "ON_DEMAND", NodeGroupType = "head-cpu" }
      tags             = merge(local.tags, { Name = "head-grp" })
      subnet_ids       = compact([
        for subnet_id, cidr_block in zipmap(module.vpc.private_subnets, module.vpc.private_subnets_cidr_blocks) :
        substr(cidr_block, 0, 4) == "100." ? subnet_id : null
      ])
    }

    worker = {
      name             = "gpu-workers-group"
      ami_type         = "AL2_x86_64_GPU"
      instance_types   = ["g4dn.xlarge"]
      min_size         = 1
      max_size         = 2
      desired_size     = 1

      labels = {
        WorkerType    = "ON_DEMAND"
        NodeGroupType = "worker-gpu"
      }

      taints = {
        gpu = {
          key      = "nvidia.com/gpu"
          effect   = "NO_SCHEDULE"
          operator = "EXISTS"
        }
      }

      # set default disk size GPU  to 200 GiB
      launch_template = {
        name    = "gpu-launch-template"
        version = "$Latest"
        block_device_mappings = {
          xvda = {
            device_name = "/dev/xvda"
            ebs = {
              volume_size = 200
              volume_type = "gp3"
              encrypted   = true
            }
          }
        }
      }

      tags = merge(local.tags, { Name = "gpu-node-grp" })
      subnet_ids = compact([
        for subnet_id, cidr_block in zipmap(module.vpc.private_subnets, module.vpc.private_subnets_cidr_blocks) :
        substr(cidr_block, 0, 4) == "100." ? subnet_id : null
      ])
    }
  }

  tags = merge(local.tags, { "karpenter.sh/discovery" = local.name })
}

################################################################################
# ADDONS: Karpenter, EBS CSI, etc.
################################################################################
module "eks_blueprints_addons" {
  source  = "aws-ia/eks-blueprints-addons/aws"
  version = "~> 1.16.2"

  cluster_name      = module.eks.cluster_name
  cluster_endpoint  = module.eks.cluster_endpoint
  cluster_version   = module.eks.cluster_version
  oidc_provider_arn = module.eks.oidc_provider_arn

  eks_addons = {
    aws-ebs-csi-driver = {
      service_account_role_arn = module.ebs_csi_driver_irsa.iam_role_arn
    }
    coredns   = { preserve = true }
    kube-proxy = { preserve = true }
    vpc-cni   = { preserve = true }
  }

  enable_karpenter = true
  karpenter_enable_spot_termination = true
  karpenter = {
    chart_version = "0.35.4"
  }
  karpenter_node = {
    iam_role_additional_policies = {
      AmazonSSMManagedInstanceCore = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
    }
  }

  enable_ingress_nginx          = false
  enable_argocd                 = false
  enable_cluster_autoscaler     = false
  enable_external_dns           = false
  enable_metrics_server         = false
  enable_velero                 = false
}

################################################################################
# IAM & STORAGE SETUP
################################################################################

# Policy untuk akses S3 dari node Karpenter
module "karpenter_policy" {
  source  = "terraform-aws-modules/iam/aws//modules/iam-policy"
  version = "~> 5.20"

  name        = "KarpenterS3AccessPolicy"
  description = "Allow Ray Workers (Karpenter nodes) to access S3"

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "ListObjectsInBucket"
        Effect = "Allow"
        Action = ["s3:ListBucket"]
        Resource = ["*"]
      },
      {
        Sid    = "AllObjectActions"
        Effect = "Allow"
        Action = "s3:*Object"
        Resource = ["*"]
      }
    ]
  })
}

resource "aws_iam_role_policy_attachment" "karpenter_attach_policy_to_role" {
  depends_on = [module.eks_blueprints_addons]
  role       = element(split("/", module.eks_blueprints_addons.karpenter.node_iam_role_arn), 1)
  policy_arn = module.karpenter_policy.arn
}

################################################################################
# EBS CSI DRIVER IRSA
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
# JUPYTERHUB IAM + QUOTA
################################################################################
resource "kubernetes_namespace_v1" "jupyterhub" {
  metadata { name = "jhub" }
}

module "jupyterhub_single_user_irsa" {
  source  = "terraform-aws-modules/iam/aws//modules/iam-role-for-service-accounts-eks"
  version = "~> 5.30"

  role_name = "jupyterhub-single-user"
  role_policy_arns = { admin = "arn:aws:iam::aws:policy/AdministratorAccess" }

  oidc_providers = {
    main = {
      provider_arn               = module.eks.oidc_provider_arn
      namespace_service_accounts = ["jhub:jupyterhub-single-user"]
    }
  }
}

resource "kubernetes_service_account_v1" "jupyterhub_single_user_sa" {
  metadata {
    name      = "jupyterhub-single-user"
    namespace = kubernetes_namespace_v1.jupyterhub.metadata[0].name
    annotations = {
      "eks.amazonaws.com/role-arn" = module.jupyterhub_single_user_irsa.iam_role_arn
    }
  }
}

################################################################################
# KARPENTER IAM POLICY
################################################################################
data "aws_iam_role" "karpenter_controller_role" {
  name = "karpenter-${local.name}-2025102107351143920000001b"
}

resource "aws_iam_policy" "karpenter_controller_passrole_policy" {
  name        = "KarpenterControllerPassRolePolicy"
  description = "Allow Karpenter controller to pass IAM roles to EC2"

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "iam:PassRole",
          "iam:CreateInstanceProfile",
          "iam:DeleteInstanceProfile",
          "iam:AddRoleToInstanceProfile",
          "iam:RemoveRoleFromInstanceProfile",
          "iam:GetInstanceProfile"
        ]
        Resource = [
          "arn:aws:iam::${local.account_id}:role/karpenter-node-role-${local.name}",
          "arn:aws:iam::${local.account_id}:role/karpenter-node-role-*"
        ]
      }
    ]
  })
}

resource "aws_iam_role_policy_attachment" "karpenter_controller_passrole_attach" {
  role       = data.aws_iam_role.karpenter_controller_role.name
  policy_arn = aws_iam_policy.karpenter_controller_passrole_policy.arn
}