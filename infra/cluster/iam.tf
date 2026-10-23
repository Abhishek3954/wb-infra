data "aws_iam_policy_document" "pods_trust" {
  statement {
    actions = ["sts:AssumeRole", "sts:TagSession"]
    principals {
      type        = "Service"
      identifiers = ["pods.eks.amazonaws.com"]
    }
  }
}

# ---- External Secrets: read exactly one secret ----
resource "aws_iam_policy" "eso" {
  name = "myapp-eso-read"
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = ["secretsmanager:GetSecretValue", "secretsmanager:DescribeSecret"]
      Resource = aws_secretsmanager_secret.db.arn
    }]
  })
}
resource "aws_iam_role" "eso" {
  name               = "myapp-eso"
  assume_role_policy = data.aws_iam_policy_document.pods_trust.json
}
resource "aws_iam_role_policy_attachment" "eso" {
  role       = aws_iam_role.eso.name
  policy_arn = aws_iam_policy.eso.arn
}
resource "aws_eks_pod_identity_association" "eso" {
  cluster_name    = module.eks.cluster_name
  namespace       = "external-secrets"
  service_account = "external-secrets"
  role_arn        = aws_iam_role.eso.arn
}

# ---- AWS Load Balancer Controller ----
resource "aws_iam_policy" "lbc" {
  name   = "myapp-lbc"
  policy = file("${path.module}/../../policies/lbc-policy.json")
}
resource "aws_iam_role" "lbc" {
  name               = "myapp-lbc"
  assume_role_policy = data.aws_iam_policy_document.pods_trust.json
}
resource "aws_iam_role_policy_attachment" "lbc" {
  role       = aws_iam_role.lbc.name
  policy_arn = aws_iam_policy.lbc.arn
}
resource "aws_eks_pod_identity_association" "lbc" {
  cluster_name    = module.eks.cluster_name
  namespace       = "kube-system"
  service_account = "aws-load-balancer-controller"
  role_arn        = aws_iam_role.lbc.arn
}

# ---- EBS CSI driver (attached to the add-on in eks.tf) ----
resource "aws_iam_role" "ebs_csi" {
  name               = "${var.cluster_name}-ebs-csi"
  assume_role_policy = data.aws_iam_policy_document.pods_trust.json
}
resource "aws_iam_role_policy_attachment" "ebs_csi" {
  role       = aws_iam_role.ebs_csi.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonEBSCSIDriverPolicy"
}
