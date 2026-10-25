resource "helm_release" "argocd" {
  name             = "argocd"
  namespace        = "argocd"
  create_namespace = true
  chart            = "${path.module}/charts/argo-cd-10.11.0.tgz"

  values = [sensitive(yamlencode({
    configs = {
      repositories = {
        gitops = {
          name          = "gitops"
          type          = "git"
          url           = var.gitops_repo_url
          sshPrivateKey = file(pathexpand(var.gitops_deploy_key_path))
        }
      }
    }
  }))]

  # nodes ready, and the controllers' credentials in place before anything starts
  depends_on = [
    module.eks,
    aws_eks_pod_identity_association.lbc,
    aws_eks_pod_identity_association.eso,
  ]
}

resource "helm_release" "root_app" {
  name      = "root-app"
  namespace = "argocd"
  chart     = "${path.module}/charts/root-app"

  set = [
    { name = "repoURL",     value = var.gitops_repo_url },
    { name = "revision",    value = var.gitops_revision },
    { name = "clusterName", value = module.eks.cluster_name },
    { name = "region",      value = var.region },
    { name = "vpcId",       value = module.vpc.vpc_id },
  ]

  depends_on = [helm_release.argocd]
}

resource "terraform_data" "teardown_guard" {
  input = {
    cluster = module.eks.cluster_name
    region  = var.region
    vpc_id  = module.vpc.vpc_id
  }

  # created last, so destroyed FIRST: before Argo CD, the cluster, and the IAM that the controllers still need
  depends_on = [
    helm_release.root_app,
    aws_eks_pod_identity_association.lbc,
    aws_eks_pod_identity_association.eso,
    aws_iam_role_policy_attachment.lbc,
    aws_iam_role_policy_attachment.eso,
  ]

  provisioner "local-exec" {
    when        = destroy
    interpreter = ["bash", "-c"]
    on_failure  = continue
    command     = <<-EOT
      aws eks update-kubeconfig --name ${self.input.cluster} --region ${self.input.region} --alias tf-teardown >/dev/null || exit 0
      K="kubectl --context tf-teardown"
      $K -n argocd delete application root --ignore-not-found --wait=false
      $K -n argocd delete application myapp --ignore-not-found --wait=true --timeout=900s
      for i in $(seq 1 60); do
        n=$(aws elbv2 describe-load-balancers --region ${self.input.region} --query "length(LoadBalancers[?VpcId=='${self.input.vpc_id}'])" --output text)
        [ "$n" = "0" ] && break
        sleep 10
      done
      for i in $(seq 1 60); do
        [ "$($K get pv --no-headers 2>/dev/null | wc -l)" -eq 0 ] && break
        sleep 10
      done
    EOT
  }
}
