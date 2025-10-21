#!/bin/bash

set -euo pipefail

REGION=${1:-"ap-southeast-1"}

echo "🚀 Starting AWS cleanup in region: $REGION"
read -p "Are you sure you want to delete resources in $REGION? (y/N): " CONFIRM
if [[ "$CONFIRM" != "y" && "$CONFIRM" != "Y" ]]; then
  echo "❌ Aborted."
  exit 0
fi

# EKS Clusters
echo "🧩 Deleting EKS clusters..."
for cluster in $(aws eks list-clusters --region "$REGION" --query 'clusters' --output text); do
  echo "  ➜ Deleting cluster: $cluster"
  for ng in $(aws eks list-nodegroups --cluster-name "$cluster" --region "$REGION" --query 'nodegroups' --output text); do
    aws eks delete-nodegroup --cluster-name "$cluster" --nodegroup-name "$ng" --region "$REGION"
  done
  aws eks delete-cluster --name "$cluster" --region "$REGION"
done

# EC2 Instances
echo "💻 Terminating EC2 instances..."
for id in $(aws ec2 describe-instances --region "$REGION" --query 'Reservations[*].Instances[*].InstanceId' --output text); do
  echo "  ➜ Terminating instance: $id"
  aws ec2 terminate-instances --instance-ids "$id" --region "$REGION"
done

# Volumes
echo "💾 Deleting unattached EBS volumes..."
for vol in $(aws ec2 describe-volumes --region "$REGION" --filters Name=status,Values=available --query 'Volumes[*].VolumeId' --output text); do
  echo "  ➜ Deleting volume: $vol"
  aws ec2 delete-volume --volume-id "$vol" --region "$REGION"
done

# S3 Buckets
echo "🪣 Deleting S3 buckets..."
for bucket in $(aws s3api list-buckets --query 'Buckets[*].Name' --output text); do
  echo "  ➜ Deleting bucket: $bucket"
  aws s3 rb "s3://$bucket" --force || true
done

# ECR Repositories
echo "🐳 Deleting ECR repositories..."
for repo in $(aws ecr describe-repositories --region "$REGION" --query 'repositories[*].repositoryName' --output text); do
  echo "  ➜ Deleting repo: $repo"
  aws ecr delete-repository --repository-name "$repo" --force --region "$REGION"
done

# CloudFormation Stacks
echo "📦 Deleting CloudFormation stacks..."
for stack in $(aws cloudformation list-stacks --region "$REGION" \
  --stack-status-filter CREATE_COMPLETE UPDATE_COMPLETE ROLLBACK_COMPLETE --query 'StackSummaries[*].StackName' --output text); do
  echo "  ➜ Deleting stack: $stack"
  aws cloudformation delete-stack --stack-name "$stack" --region "$REGION"
done

# CloudWatch Log Groups
echo "📊 Deleting CloudWatch log groups..."
for lg in $(aws logs describe-log-groups --region "$REGION" --query 'logGroups[*].logGroupName' --output text); do
  echo "  ➜ Deleting log group: $lg"
  aws logs delete-log-group --log-group-name "$lg" --region "$REGION"
done

# VPCs
echo "🌐 Deleting custom VPCs..."
for vpc in $(aws ec2 describe-vpcs --region "$REGION" --query 'Vpcs[*].VpcId' --output text); do
  if [[ "$vpc" != "vpc-"* ]]; then continue; fi
  echo "  ➜ Deleting VPC: $vpc"
  aws ec2 delete-vpc --vpc-id "$vpc" --region "$REGION" || true
done
