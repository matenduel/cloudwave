#########################################################################################################
## EKS 전용 VPC
## EKS는 서로 다른 가용 영역(AZ)의 서브넷을 최소 2개 요구합니다.
## 퍼블릭 서브넷 2개만 두고 노드도 여기에 배치하는 단순 구성입니다.
## NAT 게이트웨이가 없어 만들고 지우는 시간이 짧고, destroy 후 남는 자원(EIP 등)도 없습니다.
## 실무에서는 노드를 프라이빗 서브넷 + NAT 뒤에 두는 구성이 일반적입니다.
#########################################################################################################

data "aws_availability_zones" "available" {
  state = "available"
}

resource "aws_vpc" "eks" {
  cidr_block           = "10.0.0.0/16"
  enable_dns_support   = true
  enable_dns_hostnames = true

  tags = {
    Name = "${var.cluster_name}-vpc"
  }
}

#########################################################################################################
## Public Subnet 2개 (AZ 2곳)
#########################################################################################################
resource "aws_subnet" "public_a" {
  vpc_id                  = aws_vpc.eks.id
  cidr_block              = "10.0.1.0/24"
  availability_zone       = data.aws_availability_zones.available.names[0]
  map_public_ip_on_launch = true

  tags = {
    Name = "${var.cluster_name}-public-0"
    # 로드밸런서(ALB/NLB)가 배치될 서브넷임을 알리는 태그.
    # 지금 실습에서는 쓰지 않지만, 이후 서비스를 로드밸런서로 노출할 때 필요합니다.
    "kubernetes.io/role/elb" = "1"
  }
}

resource "aws_subnet" "public_b" {
  vpc_id                  = aws_vpc.eks.id
  cidr_block              = "10.0.2.0/24"
  availability_zone       = data.aws_availability_zones.available.names[1]
  map_public_ip_on_launch = true

  tags = {
    Name                     = "${var.cluster_name}-public-1"
    "kubernetes.io/role/elb" = "1"
  }
}

#########################################################################################################
## Internet Gateway & Route Table
#########################################################################################################
resource "aws_internet_gateway" "igw" {
  vpc_id = aws_vpc.eks.id

  tags = {
    Name = "${var.cluster_name}-igw"
  }
}

resource "aws_route_table" "public" {
  vpc_id = aws_vpc.eks.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.igw.id
  }

  tags = {
    Name = "${var.cluster_name}-public-rtb"
  }
}

resource "aws_route_table_association" "public_a" {
  route_table_id = aws_route_table.public.id
  subnet_id      = aws_subnet.public_a.id
}

resource "aws_route_table_association" "public_b" {
  route_table_id = aws_route_table.public.id
  subnet_id      = aws_subnet.public_b.id
}
