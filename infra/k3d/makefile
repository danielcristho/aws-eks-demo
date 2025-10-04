.PHONY: raycluster

# include .env

# Ray
kuberay_version = 1.2.2
cluster = kuberay
service = raycluster-$(cluster)-head-svc
head_ip = 192.168.122.10
jupyterhub_version = 4.0.0

## install kubernetes network plugin
# network-plugin:
# 	kubectl apply -f $(project_path)/infra/kubernetes/base/manifests/networks/calico.yaml

## install nvidia kubernetes operator
nvidia-operator:
	helm repo add nvidia https://nvidia.github.io/gpu-operator \
	&& helm repo update
	helm install --wait --generate-name nvidia/gpu-operator --namespace kube-system
	kubectl get pods -n kube-system|grep -i nvidia

## install kuberay operator using quickstart manifests
kuberay:
	kubectl label node rpl-worker-1 node-role.kubernetes.io/worker=worker
	kubectl label node rpl-worker-2 node-role.kubernetes.io/worker=worker
	helm repo add kuberay https://ray-project.github.io/kuberay-helm \
	&& helm repo update kuberay
	helm upgrade --install kuberay-operator kuberay/kuberay-operator --version 1.2.2 --wait --debug > /dev/null

## create ray cluster
raycluster:
	helm upgrade \
		--install raycluster kuberay/ray-cluster \
		--version $(kuberay_version) \
		--values infra/kubernetes/ray/values.yaml \
		--wait --debug > /dev/null
	make restart

## JupyterHub initialize
jupyterhub-install:
	helm repo add jupyterhub https://hub.jupyter.org/helm-chart
	helm repo update

## Create pvc
jupyterhub-pvc:
	kubectl create namespace jhub --dry-run=client -o yaml | kubectl apply -f -
	kubectl apply -f infra/kubernetes/jupyterlab/manifests/pvc.yaml

## Create JupyterHub cluster
jupyterhub-cluster:
	helm upgrade --cleanup-on-fail \
		--install jhub jupyterhub/jupyterhub \
		--namespace jhub \
		--version=$(jupyterhub_version) \
		--values infra/kubernetes/jupyterlab/values.yaml \
		--wait --debug

## port forward the service
ray-forward:
	kubectl port-forward svc/$(service) 10001:10001 8265:8265 6379:6379 --address=0.0.0.0

## Expose jupyterhub
jupyterhub-forward:
	kubectl --namespace=jhub port-forward service/proxy-public 8080:http --address 0.0.0.0

## restart the ray cluster
restart:
	kubectl delete pod -lapp.kubernetes.io/name=kuberay --wait=false || true

## get shell on head pod
shell:
	kubectl exec -i -t service/$(service) -- /bin/bash

## print ray commit
version: $(venv)
	$(venv)/bin/python -c 'import ray; print(f"{ray.__version__} {ray.__commit__}")'

## remove cluster
delete:
	kubectl delete raycluster raycluster-$(cluster)

## head node logs
logs-head:
	kubectl logs -lray.io/cluster=raycluster-$(cluster) -lray.io/node-type=head -c ray-head -f

## worker node logs
logs-worker:
	kubectl logs -lray.io/group=workergroup -f

## auto-scaler logs
logs-as:
	kubectl logs -lray.io/cluster=raycluster-$(cluster) -lray.io/node-type=head -c autoscaler -f

## list jobs
job-list: $(venv)
	$(venv)/bin/ray job list --address http://$(head_ip):8265