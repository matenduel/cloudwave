#########################################################################################################
## EKS Cluster (terraform-aws-modules/eks v21)
## 모듈 버전은 정확히 고정합니다. 모듈 버전은 .terraform.lock.hcl에 기록되지 않으므로,
## 범위로 열어 두면 실행 시점에 따라 서로 다른 모듈 버전을 받게 됩니다.
#########################################################################################################
module "eks" {
  source  = "terraform-aws-modules/eks/aws"
  version = "21.24.0"

  name               = var.cluster_name
  kubernetes_version = var.kubernetes_version

  # 노트북의 kubectl에서 API 서버로 바로 접근하기 위한 설정.
  # 접근 자체는 열려 있어도 인증 없이는 아무것도 할 수 없고, 클러스터는 실습 후 destroy로 지웁니다.
  # (실무에서는 endpoint_public_access_cidrs로 허용 대역을 좁히거나 프라이빗 엔드포인트를 씁니다.)
  endpoint_public_access = true

  # apply를 실행한 자격 증명(= 본인)에게 클러스터 관리자 권한을 부여
  enable_cluster_creator_admin_permissions = true

  vpc_id     = aws_vpc.eks.id
  subnet_ids = [aws_subnet.public_a.id, aws_subnet.public_b.id]

  # 실습용 단순화: 고객 관리 KMS 키를 만들지 않습니다(키는 destroy 후에도 30일 삭제 대기로 계정에 남음).
  # 이 경우에도 EKS는 AWS 소유 키로 기본 암호화를 수행하므로 "암호화 없음"이 아닙니다.
  create_kms_key    = false
  encryption_config = null

  #######################################################################################################
  ## 애드온
  ## vpc-cni와 pod-identity-agent는 노드보다 먼저(before_compute) 깔려야
  ## 노드가 처음 뜰 때부터 파드 네트워크와 권한 연결이 동작합니다.
  #######################################################################################################
  addons = {
    coredns    = {}
    kube-proxy = {}
    vpc-cni = {
      before_compute = true
    }
    eks-pod-identity-agent = {
      before_compute = true
    }
    # kubectl top, HPA가 쓰는 순간 자원 사용량 집계(커뮤니티 애드온, 장기 저장은 하지 않음)
    metrics-server = {}
    # PVC로 EBS 볼륨을 만들 때 필요합니다(이후 헬름 실습에서 사용).
    # EBS를 다룰 IAM 권한은 아래 Pod Identity 역할로 부여합니다.
    # EKS 1.30부터 기본 StorageClass가 없으므로, 애드온이 기본 StorageClass를 만들도록 켭니다.
    # 이게 없으면 storageClassName을 안 적은 PVC가 Pending에 머뭅니다.
    aws-ebs-csi-driver = {
      configuration_values = jsonencode({
        defaultStorageClass = {
          enabled = true
        }
      })
      pod_identity_association = [{
        role_arn        = aws_iam_role.ebs_csi.arn
        service_account = "ebs-csi-controller-sa"
      }]
    }
  }

  #######################################################################################################
  ## Managed Node Group
  #######################################################################################################
  eks_managed_node_groups = {
    default = {
      instance_types = ["t3.medium"]

      # 노드는 최초 생성 시 desired_size인 2대로 만들어집니다. max_size는 자동 확장이 아니라
      # 수동 조정이나 autoscaler를 붙였을 때 허용되는 상한입니다.
      min_size     = 2
      max_size     = 3
      desired_size = 2
    }
  }
}

#########################################################################################################
## EBS CSI 드라이버용 IAM 역할 (Pod Identity)
## ebs-csi-controller 파드가 이 역할을 이어받아 EBS 볼륨을 만들고 붙입니다.
#########################################################################################################
resource "aws_iam_role" "ebs_csi" {
  name = "${var.cluster_name}-ebs-csi"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Principal = {
          Service = "pods.eks.amazonaws.com"
        }
        Action = [
          "sts:AssumeRole",
          "sts:TagSession"
        ]
      }
    ]
  })
}

resource "aws_iam_role_policy_attachment" "ebs_csi" {
  role       = aws_iam_role.ebs_csi.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonEBSCSIDriverPolicy"
}

#########################################################################################################
## Outputs
#########################################################################################################
output "cluster_name" {
  value = module.eks.cluster_name
}

output "region" {
  value = var.region
}

output "update_kubeconfig_command" {
  description = "apply가 끝난 뒤 kubectl 연결에 쓸 명령"
  value       = "aws eks update-kubeconfig --region ${var.region} --name ${module.eks.cluster_name}"
}
