#! S3
create-bucket:
	python3 infra/scripts/create_s3.py


#! EKS Testing
create-gpu-cluster:
	cd infra/scripts && sh create_gpu_cluster.sh
