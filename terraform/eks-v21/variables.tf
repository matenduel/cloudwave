#########################################################################################################
## 실습 중 바꿀 수 있는 값만 변수로 뺐습니다.
#########################################################################################################

variable "region" {
  description = "자원을 만들 AWS 지역"
  type        = string
  default     = "ap-northeast-2"
}

variable "cluster_name" {
  description = "EKS 클러스터 이름"
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
  # 학생 실습 스펙 — 문제에 따라 Kafka 등 무거운 워크로드를 클러스터에 띄울 수 있어
  # t계열 소형으로는 부족합니다. 일요일 최종 테스트에서 m/r 계열 large로 검증 예정.
  # 강사 리허설·반복 테스트는 -var node_instance_type=t3.small 로 낮춰 실행합니다.
  default = "m5.large"
}

variable "node_count" {
  description = "노드 개수"
  type        = number
  default     = 2
}
