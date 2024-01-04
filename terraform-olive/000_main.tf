#########################################################################################################
## Configure the AWS Provider
#########################################################################################################
provider "aws" {
  access_key = var.aws_access_key
  secret_key = var.aws_secret_key
  token      = var.aws_session_token

  region = "ap-northeast-2"

  default_tags {
    tags = {
      managed_by = "terraform"
    }
  }
}