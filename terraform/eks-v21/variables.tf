#########################################################################################################
## 실습 중 바꿀 수 있는 값만 변수로 뺐습니다.
#########################################################################################################

variable "region" {
  description = "자원을 만들 AWS 리전"
  type        = string
  default     = "ap-northeast-2"
}

variable "cluster_name" {
  description = "EKS 클러스터 이름. VPC 등 부속 자원 이름의 접두어로도 쓰입니다"
  type        = string
  default     = "wave-eks"
}

variable "kubernetes_version" {
  description = "EKS 쿠버네티스 버전"
  type        = string
  default     = "1.34"
}

variable "node_instance_type" {
  description = "노드 인스턴스 타입"
  type        = string
  # 학생 실습 스펙. 문제에 따라 Kafka 등 무거운 워크로드를 클러스터에 띄울 수 있어
  # t계열 소형으로는 부족합니다. 일요일 최종 테스트에서 m/r 계열 large로 검증 예정.
  # 강사 리허설·반복 테스트는 -var node_instance_type=t3.small 로 낮춰 실행합니다.
  default = "m5.large"
}

variable "node_count" {
  description = "노드 개수"
  type        = number
  default     = 2
}

variable "owner" {
  description = "자원 소유자 태그 값. 본인 이름이나 ID로 바꾸면 콘솔에서 자기 자원을 찾기 쉽습니다"
  type        = string
  default     = "cloudwave-student"
}

variable "public_access_cidrs" {
  description = "EKS API 퍼블릭 엔드포인트 접근을 허용할 CIDR 목록. 내 IP /32로 좁히기를 권장합니다"
  type        = list(string)
  # 수업에서는 전체 개방(0.0.0.0/0)으로 시작합니다. 수강생마다 IP가 다르고, 자리 이동이나
  # 핫스팟 전환으로 IP가 바뀌면 kubectl이 갑자기 끊겨 첫 실행에서 막히기 때문입니다.
  # 이 코드를 개인 프로젝트에 다시 쓸 때는 반드시 내 IP로 좁히십시오.
  #   curl ifconfig.me   →  나온 주소를 ["x.x.x.x/32"] 형태로 적습니다.
  # 전체 개방이어도 인증 없이는 명령이 통하지 않지만, API 서버라는 문을
  # 인터넷 전체에 보여 줄 이유가 없습니다. 접근 대역은 좁힐수록 좋습니다.
  default = ["0.0.0.0/0"]

  # 왜 검증이 필요한가: 빈 리스트를 주면 plan은 통과하지만 EKS API 서버가 아무 CIDR도
  # 허용하지 않는 상태가 되어 apply 뒤에야 kubectl이 막힙니다. 오타난 CIDR(자릿수 오류,
  # IPv6 표기 등)도 마찬가지로 plan에서는 걸러지지 않고 EKS API 단계나 그 이후에야
  # 드러납니다. 45명이 각자 이 값을 손으로 바꿔 쓰는 실습이라 오타 가능성이 높으므로,
  # 여기서 미리 막아 실패 시점을 plan 이전으로 당깁니다.
  validation {
    condition = length(var.public_access_cidrs) > 0 && alltrue([
      for cidr in var.public_access_cidrs : can(cidrhost(cidr, 0))
    ])
    error_message = "public_access_cidrs는 비어 있으면 안 되고, 각 값은 유효한 CIDR 표기여야 합니다(예: \"x.x.x.x/32\")."
  }
}
