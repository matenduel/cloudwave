terraform {
  required_version = "1.6.6"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
  }

  # backend 없음: state는 실행한 폴더의 terraform.tfstate(로컬)에 저장됩니다.
  # 각자 계정에서 만들고 지우는 실습용 구성이라 remote backend를 쓰지 않습니다.
}
