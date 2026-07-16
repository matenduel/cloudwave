#########################################################################################################
## Configure the AWS Provider
#########################################################################################################
provider "aws" {
  region = var.region

  default_tags {
    tags = {
      managed_by = "terraform"
      project    = "cloudwave-eks"
    }
  }
}
