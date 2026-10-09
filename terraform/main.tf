# IRSA sample: pods assume an IAM role via the cluster's OIDC provider.
# No static AWS keys anywhere. Assumes an existing EKS cluster.

terraform {
  required_providers {
    aws        = { source = "hashicorp/aws", version = "~> 5.0" }
    kubernetes = { source = "hashicorp/kubernetes", version = "~> 2.0" }
  }
}

variable "cluster_name" { type = string }
variable "namespace" {
  type    = string
  default = "default"
}
variable "service_account" {
  type    = string
  default = "legacy-web-legacy-web" # matches helm release "legacy-web" + chart name
}

data "aws_eks_cluster" "this" { name = var.cluster_name }
data "aws_caller_identity" "current" {}

locals {
  oidc_issuer = replace(data.aws_eks_cluster.this.identity[0].oidc[0].issuer, "https://", "")
}

resource "aws_iam_openid_connect_provider" "eks" {
  url             = data.aws_eks_cluster.this.identity[0].oidc[0].issuer
  client_id_list  = ["sts.amazonaws.com"]
  thumbprint_list = ["9e99a48a9960b14926bb7f3b02e22da2b0ab7280"] # Amazon root CA; ignored by AWS for EKS OIDC
}

# Trust policy scoped to exactly one ServiceAccount.
data "aws_iam_policy_document" "assume" {
  statement {
    actions = ["sts:AssumeRoleWithWebIdentity"]
    principals {
      type        = "Federated"
      identifiers = [aws_iam_openid_connect_provider.eks.arn]
    }
    condition {
      test     = "StringEquals"
      variable = "${local.oidc_issuer}:sub"
      values   = ["system:serviceaccount:${var.namespace}:${var.service_account}"]
    }
    condition {
      test     = "StringEquals"
      variable = "${local.oidc_issuer}:aud"
      values   = ["sts.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "app" {
  name               = "legacy-web"
  assume_role_policy = data.aws_iam_policy_document.assume.json
}

# Least privilege: read one secret path only.
data "aws_iam_policy_document" "app" {
  statement {
    actions   = ["secretsmanager:GetSecretValue", "secretsmanager:DescribeSecret"]
    resources = ["arn:aws:secretsmanager:*:${data.aws_caller_identity.current.account_id}:secret:legacy-web/*"]
  }
}

resource "aws_iam_role_policy" "app" {
  role   = aws_iam_role.app.id
  policy = data.aws_iam_policy_document.app.json
}

# Alternative to the Helm-created SA: let Terraform own it.
resource "kubernetes_service_account" "app" {
  metadata {
    name        = var.service_account
    namespace   = var.namespace
    annotations = { "eks.amazonaws.com/role-arn" = aws_iam_role.app.arn }
  }
}

output "role_arn" { value = aws_iam_role.app.arn }
