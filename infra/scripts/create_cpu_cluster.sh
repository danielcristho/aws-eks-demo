eksctl create cluster \
--name=demo-cluster \
--region=ap-southeast-1 \
--version=1.28 \
--nodegroup-name=cpu-workers \
--node-type=t3.medium \
--nodes=2 \
--nodes-min=2 \
--nodes-max=3