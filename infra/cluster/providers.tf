provider "aws" {
  region = var.region
  default_tags {
    tags = { project = var.cluster_name, ManagedBy = "terraform" }
  }
}
