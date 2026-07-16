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

  # API 서버 퍼블릭 엔드포인트: 노트북의 kubectl이 인터넷을 거쳐 API 서버로 바로 접근합니다.
  # "열려 있다"는 문이 보인다는 뜻이지 아무나 들어온다는 뜻이 아닙니다. 모든 요청은 인증을
  # 통과해야 합니다(사람의 kubectl 접근은 IAM으로 인증됩니다). 그래도 문을 보여 줄 대역은
  # 좁힐수록 좋으므로 허용 CIDR을 변수로 뺐습니다
  # (기본값과 좁히는 법은 variables.tf의 public_access_cidrs 주석 참고).
  # 실무 정석은 퍼블릭 엔드포인트를 끈 프라이빗 전용 + VPN이지만, 접속 환경이 제각각인
  # 실습에서는 퍼블릭 + CIDR 제한이 현실적인 절충입니다.
  # 노드는 VPC 안의 프라이빗 엔드포인트로 API 서버와 통신하므로(모듈 기본값
  # endpoint_private_access = true), 퍼블릭 CIDR을 좁혀도 노드 통신은 끊기지 않습니다.
  endpoint_public_access       = true
  endpoint_public_access_cidrs = var.public_access_cidrs

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
  ## 보안 그룹
  ## plan 목록에 보이던 security_group들은 모듈이 자동으로 만드는 두 개입니다.
  ##  - cluster SG: 컨트롤 플레인(API 서버)의 네트워크 인터페이스에 붙습니다.
  ##    노드에서 오는 443만 받습니다.
  ##  - node SG: 모든 노드에 붙습니다. 인바운드는 노드끼리의 통신과, 컨트롤 플레인에서
  ##    노드로 가는 통신(kubelet 10250, webhook 등)만 허용합니다. 인터넷에서 노드로
  ##    들어오는 인바운드는 기본적으로 하나도 없습니다. (아웃바운드는 전부 허용입니다.
  ##    이 외에 EKS 서비스 자체가 만드는 기본(primary) cluster SG도 하나 더 생깁니다.)
  ## 인바운드 기준으로 "필요한 통신만 열린 상태"가 기본값이므로 여기서는 아무것도 더 적지 않습니다.
  ##
  ## 추가 인바운드가 필요해지면(예: NodePort로 데모 서비스를 잠깐 열어 볼 때) 노드 SG에
  ## 규칙을 더합니다. 기본은 닫아 두고, 필요할 때만 아래 주석을 풀어 내 IP로 한정해 엽니다.
  # node_security_group_additional_rules = {
  #   nodeport_demo = {
  #     description = "NodePort 데모용 임시 개방"
  #     protocol    = "tcp"
  #     from_port   = 30000
  #     to_port     = 32767
  #     type        = "ingress"
  #     cidr_blocks = ["x.x.x.x/32"] # curl ifconfig.me 로 확인한 내 IP
  #   }
  # }
  #######################################################################################################

  #######################################################################################################
  ## Managed Node Group
  #######################################################################################################
  eks_managed_node_groups = {
    default = {
      instance_types = [var.node_instance_type]

      # 노드는 최초 생성 시 node_count대로 만들어집니다. max_size는 자동 확장이 아니라
      # 수동 조정이나 autoscaler를 붙였을 때 허용되는 상한입니다.
      min_size     = var.node_count
      max_size     = var.node_count + 1
      desired_size = var.node_count
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
