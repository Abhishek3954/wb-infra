resource "helm_release" "argocd" {
  name             = "argocd"
  namespace        = "argocd"
  create_namespace = true
  chart            = "${path.module}/charts/argo-cd-10.11.0.tgz"

  values = [sensitive(yamlencode({
    configs = {
      cm = {
        "resource.customizations.health.argoproj.io_Application" = <<-LUA
          hs = {}
          hs.status = "Progressing"
          hs.message = ""
          if obj.status ~= nil and obj.status.health ~= nil then
            hs.status = obj.status.health.status
            if obj.status.health.message ~= nil then
              hs.message = obj.status.health.message
            end
          end
          return hs
        LUA
      }
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
    # no on_failure: any failure or timeout STOPS the destroy; fix the cause and run destroy again
    command = <<-EOT
      set -euo pipefail
      R=${self.input.region}; VPC=${self.input.vpc_id}; C=${self.input.cluster}

      wait_until() {  # description, seconds, command...
        local what=$1 end=$(( $(date +%s) + $2 )); shift 2
        until "$@"; do
          [ "$(date +%s)" -lt "$end" ] || { echo "TIMED OUT waiting for: $what" >&2; exit 1; }
          sleep 10
        done
        echo "ok: $what"
      }
      no_lbs()     { [ "$(aws elbv2 describe-load-balancers --region $R --query "length(LoadBalancers[?VpcId=='$VPC'])" --output text)" = "0" ]; }
      vols_gone()  { for v in $VOLS; do aws ec2 describe-volumes --region $R --volume-ids $v >/dev/null 2>&1 && return 1; done; return 0; }

      VOLS=""
      if aws eks describe-cluster --name $C --region $R >/dev/null 2>&1; then
        aws eks update-kubeconfig --name $C --region $R --alias tf-teardown >/dev/null
        K="kubectl --context tf-teardown"
        VOLS=$($K get pv -o jsonpath='{range .items[?(@.spec.csi.driver=="ebs.csi.aws.com")]}{.spec.csi.volumeHandle}{"\n"}{end}')
        echo "EBS volumes to be removed: $${VOLS:-none}"

        # Detach the root Application first so its Argo finalizer does not delete
        # child Applications concurrently. Then remove the Ingress-owning app
        # while the AWS Load Balancer Controller is still running.
        if $K -n argocd get application root >/dev/null 2>&1; then
          $K -n argocd patch application root --type=merge -p='{"spec":{"syncPolicy":{"automated":null}}}'
          $K -n argocd patch application root --type=merge -p='{"metadata":{"finalizers":[]}}'
          $K -n argocd delete application root --ignore-not-found --wait=true --timeout=120s
        fi

        # Ensure legacy live Applications also cascade-delete their resources.
        if $K -n argocd get application myapp >/dev/null 2>&1; then
          $K -n argocd patch application myapp --type=merge -p='{"metadata":{"finalizers":["resources-finalizer.argocd.argoproj.io"]}}'
        fi
        $K -n argocd delete application myapp --ignore-not-found --wait=true --timeout=900s

        # Applications may have been deleted manually without their resource
        # finalizer, leaving Ingresses behind. Delete them while the controller
        # is still running so it can remove the AWS load balancers cleanly.
        $K delete ingress --all --all-namespaces --ignore-not-found --wait=true --timeout=900s

        # The Ingress finalizer/controller gets first chance to clean up. If
        # AWS still has an orphan after the Application is fully deleted, remove
        # it directly and wait for ELBv2 to finish asynchronous deletion.
        ALBS=$(aws elbv2 describe-load-balancers --region $R --query "LoadBalancers[?VpcId=='$VPC'].LoadBalancerArn" --output text 2>/dev/null || true)
        if [ -n "$ALBS" ] && [ "$ALBS" != "None" ]; then
          echo "Found orphaned load balancers after Ingress cleanup. Deleting via AWS CLI..."
          for alb in $ALBS; do
            aws elbv2 delete-load-balancer --region $R --load-balancer-arn "$alb" || true
          done
        fi
        wait_until "no load balancers after myapp Ingress cleanup" 900 no_lbs

        # With the Ingress gone and its AWS load balancer removed, it is safe
        # to tear down the controller and all remaining Argo CD applications.
        $K -n argocd delete applications --all --ignore-not-found --wait=true --timeout=900s

        # Also clear namespaces left behind by Applications deleted without
        # Argo resource finalizers. Preserve Kubernetes and Argo CD namespaces.
        for ns in $($K get namespaces -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}'); do
          case "$ns" in
            default|kube-system|kube-public|kube-node-lease|argocd) continue ;;
          esac
          $K delete namespace "$ns" --ignore-not-found --wait=true --timeout=600s
        done

        $K delete pvc --all-namespaces --all --ignore-not-found --wait=true --timeout=600s
        wait_until "no persistent volumes left" 900 bash -c "[ \"\$($K get pv --no-headers 2>/dev/null | wc -l)\" -eq 0 ]"
      else
        echo "cluster is already gone, checking the AWS side only"
      fi

      # Catch any ELBv2 load balancers left behind if the cluster was already gone.
      ALBS=$(aws elbv2 describe-load-balancers --region $R --query "LoadBalancers[?VpcId=='$VPC'].LoadBalancerArn" --output text 2>/dev/null || true)
      if [ -n "$ALBS" ] && [ "$ALBS" != "None" ]; then
        echo "Found orphaned load balancers. Forcibly deleting them via AWS CLI..."
        for alb in $ALBS; do
          aws elbv2 delete-load-balancer --region $R --load-balancer-arn "$alb" || true
        done
      fi

      wait_until "no load balancers in the VPC" 900 no_lbs
      wait_until "EBS volumes deleted" 900 vols_gone
      echo "teardown guard: everything is gone"
    EOT
  }
}
