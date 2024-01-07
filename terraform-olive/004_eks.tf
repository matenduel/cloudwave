#########################################################################################################
## Create eks cluster
#########################################################################################################
module "eks" {
  source          = "terraform-aws-modules/eks/aws"
  version         = "~> 19.0"
  cluster_name    = var.cluster-name
  cluster_version = var.cluster-version

  cluster_endpoint_public_access  = true
  cluster_endpoint_private_access = true

  cluster_addons = {
    coredns = {
      most_recent = true
    }
    kube-proxy = {
      most_recent = true
    }
    vpc-cni = {
      cluster_name = var.cluster-name
      most_recent = true
    }
  }

  vpc_id                   = aws_vpc.vpc.id
  subnet_ids               = [aws_subnet.private-subnet-a.id, aws_subnet.private-subnet-c.id]


  # EKS Managed Node Group
  eks_managed_node_group_defaults = {
    instance_types = ["m7i.large"]
  }

  eks_managed_node_groups = {
    green = {
      min_size     = 2
      max_size     = 2
      desired_size = 2

      instance_types = ["m7i.large"]
    }
  }
}