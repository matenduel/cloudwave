#########################################################################################################
## AWS Load Balancer Controller(LBC)용 IAM (Pod Identity)
## LBC는 Ingress/Service를 보고 ALB·NLB를 대신 만들어 주는 컨트롤러입니다. 로드밸런서를
## "만드는" 주체가 클러스터 안의 파드이므로, 그 파드에게 AWS API를 부를 권한이 필요합니다.
## 권한 연결은 EBS CSI와 같은 Pod Identity 방식입니다: 역할을 만들고, 파드의 서비스어카운트에
## 연결(association)해 두면, 파드가 뜰 때 pod-identity-agent가 자격 증명을 넣어 줍니다.
## 여기서는 IAM 쪽 준비(정책→역할→연결)까지만 하고, 컨트롤러 자체는 헬름 실습에서 설치합니다.
#########################################################################################################

# LBC가 필요로 하는 권한 정책. EBS CSI는 AWS가 관리형 정책(AmazonEBSCSIDriverPolicy)을
# 제공하지만 LBC는 관리형 정책이 없어서, 프로젝트가 배포하는 공식 정책 문서를 직접 등록합니다.
# 동반 파일 lbc_iam_policy.json 원본(수정 없이 그대로 커밋):
#   https://github.com/kubernetes-sigs/aws-load-balancer-controller
#   docs/install/iam_policy.json @ v3.4.2 (statement 16개)
# 컨트롤러를 크게 올릴 때는 새 버전의 iam_policy.json으로 이 파일도 함께 갈아야 합니다.
# 새 기능이 새 AWS API를 부르는데 정책이 옛것이면 AccessDenied로 드러납니다.
resource "aws_iam_policy" "lbc" {
  name   = "${var.cluster_name}-lbc"
  policy = file("${path.module}/lbc_iam_policy.json")
}

# 파드가 이어받을 역할. Pod Identity 방식은 신뢰 정책이 클러스터마다 달라지지 않고
# 항상 같은 모양입니다: EKS의 Pod Identity 서비스(pods.eks.amazonaws.com)만 이 역할을
# 쓸 수 있게 허용합니다. sts:TagSession은 EKS가 "어느 클러스터의 어느 파드인지"를
# 세션 태그로 남기는 데 필요해서 AssumeRole과 함께 반드시 허용해야 합니다.
resource "aws_iam_role" "lbc" {
  name = "${var.cluster_name}-lbc"

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

resource "aws_iam_role_policy_attachment" "lbc" {
  role       = aws_iam_role.lbc.name
  policy_arn = aws_iam_policy.lbc.arn
}

# 역할과 서비스어카운트를 잇는 연결(association). "kube-system 네임스페이스의
# aws-load-balancer-controller라는 서비스어카운트로 뜨는 파드는 이 역할을 쓴다"는 매핑을
# EKS 컨트롤 플레인에 등록하는 것이라서, 클러스터만 있으면 만들 수 있습니다.
# 노드나 pod-identity-agent 애드온을 기다릴 필요가 없고(그 둘은 파드가 실제로 자격 증명을
# 받는 실행 시점에 필요), 서비스어카운트가 아직 없어도 됩니다 — 이름 기준 매핑이므로
# 나중에 헬름이 같은 이름으로 서비스어카운트를 만들면 그때부터 권한이 붙습니다.
# 그래서 헬름 설치 때는 IAM 절차가 하나도 남지 않습니다.
# (서비스어카운트 이름은 LBC 헬름 차트 기본값과 맞춘 것입니다. 설치 시
#  serviceAccount.name을 다르게 주면 이 매핑이 빗나가 권한이 붙지 않습니다.)
resource "aws_eks_pod_identity_association" "lbc" {
  cluster_name    = module.eks.cluster_name
  namespace       = "kube-system"
  service_account = "aws-load-balancer-controller"
  role_arn        = aws_iam_role.lbc.arn
}
