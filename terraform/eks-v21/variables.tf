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
