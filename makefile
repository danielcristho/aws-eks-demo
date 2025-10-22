#! S3
create-bucket:
	python3 infra/scripts/create_s3.py

#! Update kubeconfig
update-kubeconfig:
	aws eks update-kubeconfig --name mlops-demo --region ap-southeast-1

#! Remove default resource quota
remove-rquota:
	kubectl delete resourcequota ml-quota-default -n ml-workload-ns

## JupyterHub Manifests ##
create-rbac:
	kubectl apply -f infra/terraform/helm/jupyterhub/manifests/rbac.yaml

create-pvc:
	kubectl apply -f infra/terraform/helm/jupyterhub/manifests/pvc.yaml

## TESTING ##

#! EKS Testing
create-gpu-cluster:
	cd infra/scripts && sh create_gpu_cluster.sh
