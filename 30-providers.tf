terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 5.0"
    }
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = ">= 2.19.0, < 3.0.0"
    }
    kubectl = {
      source  = "gavinbunney/kubectl"
      version = ">= 1.14.0"
    }
    helm = {
      source  = "hashicorp/helm"
      version = ">= 2.12.0, < 3.0.0"
    }
    random = {
      source  = "hashicorp/random"
      version = ">= 3.5.0"
    }
  }
}

# Credentials for the helm provider's OCI pull of an org's charts (mirrors the
# baseline roots; the executor role carries the ECR auth-token grant).
data "aws_eks_cluster" "cluster" {
  name = var.eks_cluster_name
}

data "aws_region" "current" {}

provider "aws" {
  default_tags {
    tags = local.provider_default_tags
  }
}

provider "aws" {
  alias  = "aws_acm"
  region = "us-east-1"
  default_tags {
    tags = local.provider_default_tags
  }
}

provider "aws" {
  alias = "aws_dns"
  default_tags {
    tags = local.provider_default_tags
  }
}

# NOTE: the exec plugin's `aws-eks-get-token-retry` is a runtime contract with
# whatever executes addon roots (deploy image OR CI checklist) — on GitHub
# runners, the example's workflows put ./bin on PATH (see bin/ + workflows).

provider "kubernetes" {
  host                   = data.aws_eks_cluster.cluster.endpoint
  cluster_ca_certificate = base64decode(data.aws_eks_cluster.cluster.certificate_authority[0].data)

  exec {
    api_version = "client.authentication.k8s.io/v1beta1"
    # Wraps `aws eks get-token` with short retries — concurrent exec-plugin
    # invocations race on the AWS CLI's local credential cache (see bin/).
    command = "aws-eks-get-token-retry"
    args = [
      "eks", "get-token",
      "--cluster-name", data.aws_eks_cluster.cluster.id,
      "--region", data.aws_region.current.region,
      "--role-arn", var.eks_cluster_role_arn,
    ]
  }
}

provider "kubectl" {
  load_config_file = false

  host                   = data.aws_eks_cluster.cluster.endpoint
  cluster_ca_certificate = base64decode(data.aws_eks_cluster.cluster.certificate_authority[0].data)

  exec {
    api_version = "client.authentication.k8s.io/v1beta1"
    command     = "aws-eks-get-token-retry"
    args = [
      "eks", "get-token",
      "--cluster-name", data.aws_eks_cluster.cluster.id,
      "--region", data.aws_region.current.region,
      "--role-arn", var.eks_cluster_role_arn,
    ]
  }
}

data "aws_ecr_authorization_token" "agent" {}

provider "helm" {
  kubernetes {
    host                   = data.aws_eks_cluster.cluster.endpoint
    cluster_ca_certificate = base64decode(data.aws_eks_cluster.cluster.certificate_authority[0].data)

    exec {
      api_version = "client.authentication.k8s.io/v1beta1"
      command     = "aws-eks-get-token-retry"
      args = [
        "eks", "get-token",
        "--cluster-name", data.aws_eks_cluster.cluster.id,
        "--region", data.aws_region.current.region,
        "--role-arn", var.eks_cluster_role_arn,
      ]
    }
  }

  registry {
    url      = "oci://308044622771.dkr.ecr.us-east-1.amazonaws.com"
    username = data.aws_ecr_authorization_token.agent.user_name
    password = data.aws_ecr_authorization_token.agent.password
  }
}
