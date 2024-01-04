#########################################################################################################
## Terraform configurations (AWS)
#########################################################################################################
variable "aws_access_key" {
  type        = string
  description = "AWS Access Key"

}
variable "aws_secret_key" {
  type        = string
  description = "AWS Secret Key"
}

variable "aws_session_token" {
  type        = string
  description = "AWS Session Token"
}


#########################################################################################################
## EKS Variable
#########################################################################################################

variable "cluster-name" {
  description = "AWS kubernetes cluster name"
  default     = "wave"
}

variable "cluster-version" {
  description = "AWS EKS supported Cluster Version to current use"
  default     = "1.27"
}