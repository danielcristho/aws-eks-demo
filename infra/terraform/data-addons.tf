# Install KubeRay Operator
resource "helm_release" "kuberay_operator" {
  name       = "kuberay-operator"
  repository = "https://ray-project.github.io/kuberay-helm/"
  chart      = "kuberay-operator"
  version    = "1.1.0"
  namespace  = "kuberay-system"
  create_namespace = true

  values = [
    <<-EOT
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

# Install NVIDIA GPU Operator
resource "helm_release" "nvidia_device_plugin" {
  name             = "nvidia-device-plugin"
  repository       = "https://nvidia.github.io/k8s-device-plugin"
  chart            = "nvidia-device-plugin"
  version          = "0.14.5"
  namespace        = "gpu-operator"
  create_namespace = true

  values = [<<-EOT
    nodeSelector:
      nvidia.com/gpu: "true"
    tolerations:
      - key: "nvidia.com/gpu"
        operator: "Exists"
        effect: "NoSchedule"
  EOT
  ]

  depends_on = [module.eks]
}

# JupyterHub Release
resource "helm_release" "jupyterhub" {
  name             = "jupyterhub"
  repository       = "https://jupyterhub.github.io/helm-chart/"
  chart            = "jupyterhub"
  version          = "4.1.0"
  namespace        = kubernetes_namespace_v1.jupyterhub.metadata[0].name 
  create_namespace = false

  values = [templatefile("${path.module}/helm/jupyterhub/values.yaml",
    { 
      jupyter_single_user_sa_name = kubernetes_service_account_v1.jupyterhub_single_user_sa.metadata[0].name
    }
  )]
  depends_on = [
    helm_release.nvidia_device_plugin, 
    kubernetes_namespace_v1.jupyterhub
  ]
}