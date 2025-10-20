# AWS Community ID Demo

## Description

This repository contains the Infrastructure as Code (IaC) for building a Cost-Optimized, Multi-Tenant Machine Learning Platform on Amazon EKS, leveraging Karpenter for intelligent autoscaling and Ray for distributed workload orchestration.

The core goal is to demonstrate Resource Isolation (ensuring tenants do not overuse shared GPU/CPU resources) and GPU-Aware Scheduling at a minimal operational cost.

## Requirements

Before starting the deployment, ensure you have:

- AWS Account: With AdministratorAccess IAM permissions (for demo only).

- AWS Service Quota: Approved for at least 8 vCPUs for G and VT instances (critical for g4dn.xlarge).

- AWS CLI, kubectl, helm, and Terraform (>= 1.0) installed and configured.

- AWS Credentials: Configured locally via `aws configure`.

## Deployment Guide