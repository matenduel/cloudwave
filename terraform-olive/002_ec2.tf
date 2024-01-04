#########################################################################################################
## Create keypair for ec2
#########################################################################################################
resource "tls_private_key" "wave-pk" {
  algorithm = "RSA"
  rsa_bits = 4096
}

resource "aws_key_pair" "wave-kp" {
  key_name = "wave-keypair"
  public_key = tls_private_key.wave-pk.public_key_openssh
}

# Download key file in local
resource "local_file" "ssh-key" {
  filename = "wave.pem"
  content = tls_private_key.wave-pk.private_key_pem
}

#########################################################################################################
## Create ec2 instance for Bastion
#########################################################################################################
resource "aws_instance" "bastion" {
  ami = "ami-086cae3329a3f7d75"
  instance_type = "t3.micro"
  subnet_id = aws_subnet.public-subnet-a.id
  tags = {
    Name = "bastion"
  }
  vpc_security_group_ids = [aws_security_group.allow-ssh-sg.id]
  key_name = aws_key_pair.wave-kp.key_name
}

# Check bastion public ip
output "bastion-public-ip" {
  value = aws_instance.bastion.public_ip
}

#########################################################################################################
## Create ec2 instance for docker
#########################################################################################################
resource "aws_instance" "docker-playground" {
  ami = "ami-086cae3329a3f7d75"
  instance_type = "t3.micro"
  subnet_id = aws_subnet.public-subnet-a.id
  tags = {
    Name = "docker-playground"
  }
  vpc_security_group_ids = [aws_security_group.allow-ssh-sg.id]
  key_name = aws_key_pair.wave-kp.key_name
}

# Check docker-playground public ip
output "docker-playground-public-ip" {
  value = aws_instance.docker-playground.public_ip
}