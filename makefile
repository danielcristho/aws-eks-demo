## S3 ##

#! Create 'tfstate' bucket
create-bucket:
	python3 infra/scripts/create_s3.py

#! Update kubeconfig
update-kubeconfig:
	aws eks update-kubeconfig --name mlops-demo --region ap-southeast-1

#! Remove default resource quota
remove-rquota:
	kubectl delete resourcequota ml-quota-default -n ml-workload-ns

## JupyterHub ##

#! SA
create-rbac:
	kubectl apply -f infra/terraform/helm/manifests/rbac.yaml

#! Create PVC
create-pvc:
	kubectl apply -f infra/terraform/helm/manifests/pvc.yaml

#! Release new changes
update-jhub:
	helm upgrade jupyterhub-cluster jupyterhub/jupyterhub \
		--namespace jhub \
		--version 4.0.0 \
		-f infra/terraform/helm/jupyterhub/values.yaml

## RAY ##

#! Release new changes
update-raycluster:
	helm upgrade --install ray-cluster ray-cluster \
		-n ray \
		-f infra/terraform/helm/ray/values.yaml \
		--repo https://ray-project.github.io/kuberay-helm/

## Karpenter ##

#! Create node pools
create-nodepool:
	kubectl apply -f infra/terraform/helm/manifests/karpenter.yaml

## TESTING ##

#! EKS Testing
create-gpu-cluster:
	cd infra/scripts && sh create_gpu_cluster.sh
