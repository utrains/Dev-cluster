# Writes a ready-to-share, read-only kubeconfig to
# kubeconfigs/team-readonly.kubeconfig on every `terraform apply`, so there is
# no separate `users.sh add` step for the common "give the team read access"
# case. Per-person files with a sandbox still come from scripts/users.sh.
#
# The read-only permissions are the same group bindings as
# rbac/cluster-access.yaml (which setup.sh and users.sh also apply, for the
# sandbox role). Keep the two in sync: identical content means kubectl apply
# and Terraform never fight over these objects.

provider "kubernetes" {
  host                   = aws_eks_cluster.main.endpoint
  cluster_ca_certificate = base64decode(aws_eks_cluster.main.certificate_authority[0].data)

  # Logs in as whoever runs terraform, through the caller access entry in eks.tf.
  exec {
    api_version = "client.authentication.k8s.io/v1beta1"
    command     = "aws"
    args        = ["eks", "get-token", "--cluster-name", aws_eks_cluster.main.name, "--region", var.region]
  }
}

resource "kubernetes_namespace" "lab_users" {
  metadata {
    name = "lab-users"
    labels = {
      "app.kubernetes.io/part-of" = "k8s-lab"
    }
  }

  # Without the caller's admin policy the API server rejects every call here.
  depends_on = [aws_eks_access_policy_association.caller_admin]
}

# Built-in `view`: read everything except Secrets, in every namespace.
resource "kubernetes_cluster_role_binding" "lab_users_view" {
  metadata {
    name = "lab-users-view"
  }
  role_ref {
    api_group = "rbac.authorization.k8s.io"
    kind      = "ClusterRole"
    name      = "view"
  }
  subject {
    api_group = "rbac.authorization.k8s.io"
    kind      = "Group"
    name      = "system:serviceaccounts:lab-users"
  }

  depends_on = [aws_eks_access_policy_association.caller_admin]
}

# `view` is namespaced only; this adds nodes, namespaces and friends.
resource "kubernetes_cluster_role" "lab_cluster_reader" {
  metadata {
    name = "lab-cluster-reader"
  }
  rule {
    api_groups = [""]
    resources  = ["nodes", "namespaces", "persistentvolumes"]
    verbs      = ["get", "list", "watch"]
  }
  rule {
    api_groups = ["storage.k8s.io"]
    resources  = ["storageclasses"]
    verbs      = ["get", "list", "watch"]
  }
  rule {
    api_groups = ["networking.k8s.io"]
    resources  = ["ingressclasses"]
    verbs      = ["get", "list", "watch"]
  }

  depends_on = [aws_eks_access_policy_association.caller_admin]
}

resource "kubernetes_cluster_role_binding" "lab_users_cluster_reader" {
  metadata {
    name = "lab-users-cluster-reader"
  }
  role_ref {
    api_group = "rbac.authorization.k8s.io"
    kind      = "ClusterRole"
    name      = kubernetes_cluster_role.lab_cluster_reader.metadata[0].name
  }
  subject {
    api_group = "rbac.authorization.k8s.io"
    kind      = "Group"
    name      = "system:serviceaccounts:lab-users"
  }
}

# Same labels as rbac/user-readonly.yaml.tpl, so `users.sh list` shows it.
resource "kubernetes_service_account" "team_readonly" {
  metadata {
    name      = "team-readonly"
    namespace = kubernetes_namespace.lab_users.metadata[0].name
    labels = {
      "lab/user" = "team-readonly"
      "lab/mode" = "readonly"
    }
  }
}

# Long-lived token, revoked by deleting it (or `terraform destroy`).
resource "kubernetes_secret" "team_readonly_token" {
  metadata {
    name      = "team-readonly-token"
    namespace = kubernetes_namespace.lab_users.metadata[0].name
    labels = {
      "lab/user" = "team-readonly"
      "lab/mode" = "readonly"
    }
    annotations = {
      "kubernetes.io/service-account.name" = kubernetes_service_account.team_readonly.metadata[0].name
    }
  }
  type                           = "kubernetes.io/service-account-token"
  wait_for_service_account_token = true
}

resource "local_sensitive_file" "team_readonly_kubeconfig" {
  filename             = "${path.module}/../kubeconfigs/team-readonly.kubeconfig"
  file_permission      = "0600"
  directory_permission = "0700"
  content = yamlencode({
    apiVersion = "v1"
    kind       = "Config"
    clusters = [{
      name = var.cluster_name
      cluster = {
        server                     = aws_eks_cluster.main.endpoint
        certificate-authority-data = aws_eks_cluster.main.certificate_authority[0].data
      }
    }]
    users = [{
      name = "team-readonly"
      user = {
        token = kubernetes_secret.team_readonly_token.data["token"]
      }
    }]
    contexts = [{
      name = var.cluster_name
      context = {
        cluster   = var.cluster_name
        user      = "team-readonly"
        namespace = "default"
      }
    }]
    current-context = var.cluster_name
  })

  # The token only works once the group bindings exist.
  depends_on = [
    kubernetes_cluster_role_binding.lab_users_view,
    kubernetes_cluster_role_binding.lab_users_cluster_reader,
  ]
}
