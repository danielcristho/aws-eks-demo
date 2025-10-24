# NVIDIA Device Plugin
resource "helm_release" "nvidia_device_plugin" {
  name             = "nvidia-device-plugin"
  repository       = "https://nvidia.github.io/k8s-device-plugin"
  chart            = "nvidia-device-plugin"
  version          = "0.14.5"
  namespace        = "kube-system"
  create_namespace = false

  values = [<<-EOT
    nodeSelector:
      NodeGroupType: worker-gpu  # Match GPU nodes
    tolerations:
      - key: "nvidia.com/gpu"
        operator: "Exists"
        effect: "NoSchedule"
  EOT
  ]

  depends_on = [module.eks]
}

# NGINX Ingress Controller
resource "helm_release" "nginx_ingress_controller" {
  name             = "nginx-ingress"
  repository       = "https://kubernetes.github.io/ingress-nginx"
  chart            = "ingress-nginx"
  version          = "4.9.1"
  namespace        = "nginx-ingress"
  create_namespace = true

  values = [
    templatefile("${path.module}/helm/nginx-ingress/values.yaml", {
      some_value = "custom"
    })
  ]

  depends_on = [module.eks]
}

# JupyterHub Release
resource "helm_release" "jupyterhub_cluster" {
  name             = "jupyterhub-cluster"
  repository       = "https://jupyterhub.github.io/helm-chart/"
  chart            = "jupyterhub"
  version          = "4.0.0"
  namespace        = "jhub"
  create_namespace = true

  values = [templatefile("${path.module}/helm/jupyterhub/values.yaml",
    { 
      jupyter_single_user_sa_name = kubernetes_service_account_v1.jupyterhub_single_user_sa.metadata[0].name
    }
  )]

  depends_on = [
    helm_release.nvidia_device_plugin,
    helm_release.nginx_ingress_controller,
    kubernetes_namespace_v1.jupyterhub
  ]
}

# KubeRay Operator
resource "helm_release" "kuberay_operator" {
  name             = "kuberay-operator"
  repository       = "https://ray-project.github.io/kuberay-helm/"
  chart            = "kuberay-operator"
  version          = "1.4.2"
  namespace        = "kuberay"
  create_namespace = true

  values = [<<-EOT
    operator:
      resources:
        limits:
          cpu: 1
          memory: 1Gi
        requests:
          cpu: 0.5
          memory: 512Mi
  EOT
  ]

  depends_on = [module.eks]
}

# Ray Cluster
resource "helm_release" "ray_cluster" {
  name             = "ray-cluster"
  repository       = "https://ray-project.github.io/kuberay-helm/"
  chart            = "ray-cluster"
  version          = "1.4.2"
  namespace        = "ray"
  create_namespace = true

  values = [
    templatefile("${path.module}/helm/ray/values.yaml", {
      karpenter_node_label = "karpenter.sh/discovery=${local.name}"
    })
  ]

  depends_on = [
    helm_release.kuberay_operator,
    helm_release.nvidia_device_plugin
  ]
}
