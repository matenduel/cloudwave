#########################################################################################################
## S3 권한 체험 실습 준비 — 노드 역할 vs Pod Identity
## "똑같은 aws s3 ls가 어떤 파드에서는 성공하고 어떤 파드에서는 거부되는" 체험 실습의 AWS 쪽
## 준비를 전부 코드로 만들어 둡니다. 학생이 하는 일은 파드 두 개를 띄워 결과를 비교하는 것뿐이고,
## 여기 리소스들이 그 대비를 미리 깔아 둡니다: 노드 역할에는 S3 읽기 권한을 붙여 "성공"을,
## 서비스어카운트에는 권한 없는 역할을 Pod Identity로 매달아 "거부"를 만듭니다.
## 쿠버네티스 쪽 준비(demo 네임스페이스, restricted 서비스어카운트)는 AWS 자원이 아니라서
## 이 파일에 없습니다 — 강사가 kubectl로 만듭니다(체험 문서의 강사 준비 노트 참고).
#########################################################################################################

# S3 버킷 이름은 전 세계 모든 AWS 계정을 통틀어 유일해야 합니다. 고정 이름을 쓰면 같은 코드를
# 실행하는 다른 계정과 반드시 충돌하므로, 실행한 계정의 ID를 서픽스로 붙여 유일성을 만듭니다.
# 계정 ID는 지금 쓰는 자격 증명에서 조회할 수 있으므로(data 소스), 값을 하드코딩하지 않습니다.
data "aws_caller_identity" "current" {}

# 실습용 버킷. 두 파드가 조회를 시도할 대상입니다.
resource "aws_s3_bucket" "perm_demo" {
  bucket = "cloudwave-perm-demo-${data.aws_caller_identity.current.account_id}"

  # 실습용 버킷은 destroy가 한 번에 완주해야 합니다. S3는 안이 비어 있지 않으면 버킷 삭제를
  # 거부하는데, force_destroy를 켜면 terraform이 destroy 때 안의 객체를 먼저 지운 뒤 버킷을
  # 지웁니다. 반대로 운영 데이터 버킷이라면 실수로 통째로 지워지는 것을 막아야 하므로
  # 켜면 안 되는 옵션입니다 — "실습용이라서" 켠 것임을 기억하십시오.
  force_destroy = true
}

# 성공했을 때 "보이는 것"을 만들어 두는 데모 객체. 빈 버킷이면 성공(빈 출력)과 거부(에러)의
# 대비가 흐려지므로, aws s3 ls가 목록으로 보여 줄 객체를 하나 넣어 둡니다.
resource "aws_s3_object" "perm_demo_readme" {
  bucket  = aws_s3_bucket.perm_demo.id
  key     = "hello-from-instructor.txt"
  content = "If you can read this listing, your pod is using the node role. (1막 성공)\n"
}

# 1막의 "성공"을 만드는 쪽: 노드 그룹의 IAM 역할에 S3 읽기 관리형 정책을 붙입니다.
# 자기 몫의 역할이 없는 파드는 노드에 붙은 역할을 물려받으므로, 이 한 줄로 그 노드 위의
# 모든 이름 없는 파드가 S3를 읽게 됩니다 — 체험의 핵심인 "노드 단위 권한 공유"입니다.
# 실습 전용 구성입니다. 실제 운영에서 노드 역할을 이렇게 넓히면 어떤 파드가 침해당해도
# 계정의 모든 버킷이 읽히므로, 운영에서는 필요한 파드에만 Pod Identity로 좁혀 줍니다.
resource "aws_iam_role_policy_attachment" "node_s3_read" {
  role       = module.eks.eks_managed_node_groups["default"].iam_role_name
  policy_arn = "arn:aws:iam::aws:policy/AmazonS3ReadOnlyAccess"
}

# 2막의 "거부"를 만드는 쪽: 권한 정책을 하나도 붙이지 않은 역할입니다. IAM은 명시적으로
# 허용하지 않은 요청을 전부 거부하므로(암묵적 거부), 빈 역할이 곧 "S3 권한이 없는 역할"입니다.
# 신뢰 정책은 EBS CSI(002)·LBC(003)와 같은 Pod Identity 표준형입니다: EKS의 Pod Identity
# 서비스(pods.eks.amazonaws.com)만 이 역할을 쓸 수 있고, sts:TagSession은 EKS가 "어느
# 클러스터의 어느 파드인지"를 세션 태그로 남기는 데 필요해 AssumeRole과 함께 허용합니다.
resource "aws_iam_role" "s3_demo_restricted" {
  name = "${var.cluster_name}-s3-demo-restricted"

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

# "demo 네임스페이스의 restricted 서비스어카운트로 뜨는 파드는 위의 빈 역할을 쓴다"는 매핑.
# Pod Identity는 노드 역할에 권한을 더하는 게 아니라 자리를 통째로 바꿔 끼우므로, 이 매핑이
# 걸린 파드는 노드 역할의 넓은 S3 권한을 잃습니다 — 그것이 2막의 AccessDenied입니다.
# 네임스페이스·서비스어카운트 이름은 체험 문서의 파드 스펙과 맞춘 값입니다. 매핑은 이름
# 기준이라 서비스어카운트가 아직 없어도 만들 수 있고(003의 LBC와 같은 성질), 나중에 강사가
# kubectl로 같은 이름의 서비스어카운트를 만들면 그때부터 권한이 붙습니다.
resource "aws_eks_pod_identity_association" "s3_demo_restricted" {
  cluster_name    = module.eks.cluster_name
  namespace       = "demo"
  service_account = "restricted"
  role_arn        = aws_iam_role.s3_demo_restricted.arn
}
