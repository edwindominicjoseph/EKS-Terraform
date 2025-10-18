# ----------------------------------------------------
# PROVIDER
# ----------------------------------------------------
provider "aws" {
  region = "us-east-1"
}

# ----------------------------------------------------
# LOCALS
# ----------------------------------------------------
locals {
  azs = ["us-east-1a", "us-east-1b"]
}

# ----------------------------------------------------
# VPC
# ----------------------------------------------------
resource "aws_vpc" "devopsshack_vpc" {
  cidr_block           = "10.0.0.0/16"
  enable_dns_support   = true
  enable_dns_hostnames = true

  tags = {
    Name = "devopsshack-vpc"
  }
}

# ----------------------------------------------------
# PUBLIC SUBNETS
# ----------------------------------------------------
resource "aws_subnet" "public" {
  count                   = length(local.azs)
  vpc_id                  = aws_vpc.devopsshack_vpc.id
  cidr_block              = cidrsubnet(aws_vpc.devopsshack_vpc.cidr_block, 8, count.index)
  availability_zone       = local.azs[count.index]
  map_public_ip_on_launch = true

  tags = {
    Name                     = "devopsshack-public-${local.azs[count.index]}"
    "kubernetes.io/role/elb" = "1"
  }
}

# ----------------------------------------------------
# PRIVATE SUBNETS
# ----------------------------------------------------
resource "aws_subnet" "private" {
  count            = length(local.azs)
  vpc_id           = aws_vpc.devopsshack_vpc.id
  cidr_block       = cidrsubnet(aws_vpc.devopsshack_vpc.cidr_block, 8, count.index + 10)
  availability_zone = local.azs[count.index]

  tags = {
    Name                              = "devopsshack-private-${local.azs[count.index]}"
    "kubernetes.io/role/internal-elb" = "1"
  }
}

# ----------------------------------------------------
# INTERNET GATEWAY
# ----------------------------------------------------
resource "aws_internet_gateway" "igw" {
  vpc_id = aws_vpc.devopsshack_vpc.id

  tags = {
    Name = "devopsshack-igw"
  }
}

# ----------------------------------------------------
# ELASTIC IPs FOR NAT
# ----------------------------------------------------
resource "aws_eip" "nat_eip" {
  count  = length(local.azs)
  domain = "vpc"

  tags = {
    Name = "devopsshack-nat-eip-${local.azs[count.index]}"
  }
}

# ----------------------------------------------------
# NAT GATEWAYS
# ----------------------------------------------------
resource "aws_nat_gateway" "nat" {
  count         = length(local.azs)
  allocation_id = aws_eip.nat_eip[count.index].id
  subnet_id     = aws_subnet.public[count.index].id

  tags = {
    Name = "devopsshack-nat-${local.azs[count.index]}"
  }

  depends_on = [aws_internet_gateway.igw]
}

# ----------------------------------------------------
# ROUTE TABLES
# ----------------------------------------------------

# Public route table (routes via IGW)
resource "aws_route_table" "public" {
  vpc_id = aws_vpc.devopsshack_vpc.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.igw.id
  }

  tags = {
    Name = "devopsshack-public-rt"
  }
}

# Private route table (routes via NAT)
resource "aws_route_table" "private" {
  count  = length(local.azs)
  vpc_id = aws_vpc.devopsshack_vpc.id

  route {
    cidr_block     = "0.0.0.0/0"
    nat_gateway_id = aws_nat_gateway.nat[count.index].id
  }

  tags = {
    Name = "devopsshack-private-rt-${local.azs[count.index]}"
  }
}

# ----------------------------------------------------
# ROUTE TABLE ASSOCIATIONS
# ----------------------------------------------------

# Public
resource "aws_route_table_association" "public_assoc" {
  count          = length(local.azs)
  subnet_id      = aws_subnet.public[count.index].id
  route_table_id = aws_route_table.public.id
}

# Private
resource "aws_route_table_association" "private_assoc" {
  count          = length(local.azs)
  subnet_id      = aws_subnet.private[count.index].id
  route_table_id = aws_route_table.private[count.index].id
}

# ----------------------------------------------------
# SECURITY GROUPS
# ----------------------------------------------------
resource "aws_security_group" "devopsshack_cluster_sg" {
  vpc_id = aws_vpc.devopsshack_vpc.id

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "devopsshack-cluster-sg"
  }
}

resource "aws_security_group" "devopsshack_node_sg" {
  vpc_id = aws_vpc.devopsshack_vpc.idls

  ingress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "devopsshack-node-sg"
  }
}

# ----------------------------------------------------
# IAM ROLES
# ----------------------------------------------------

# EKS Cluster Role
resource "aws_iam_role" "devopsshack_cluster_role" {
  name = "devopsshack-cluster-role"

  assume_role_policy = <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Principal": { "Service": "eks.amazonaws.com" },
      "Action": "sts:AssumeRole"
    }
  ]
}
EOF
}

resource "aws_iam_role_policy_attachment" "devopsshack_cluster_role_policy" {
  role       = aws_iam_role.devopsshack_cluster_role.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKSClusterPolicy"
}

# Node Group Role
resource "aws_iam_role" "devopsshack_node_group_role" {
  name = "devopsshack-node-group-role"

  assume_role_policy = <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Principal": { "Service": "ec2.amazonaws.com" },
      "Action": "sts:AssumeRole"
    }
  ]
}
EOF
}

resource "aws_iam_role_policy_attachment" "devopsshack_node_group_role_policy" {
  role       = aws_iam_role.devopsshack_node_group_role.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKSWorkerNodePolicy"
}

resource "aws_iam_role_policy_attachment" "devopsshack_node_group_cni_policy" {
  role       = aws_iam_role.devopsshack_node_group_role.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKS_CNI_Policy"
}

resource "aws_iam_role_policy_attachment" "devopsshack_node_group_registry_policy" {
  role       = aws_iam_role.devopsshack_node_group_role.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryReadOnly"
}

# ----------------------------------------------------
# EKS CLUSTER
# ----------------------------------------------------
resource "aws_eks_cluster" "devopsshack" {
  name     = "devopsshack-cluster"
  role_arn = aws_iam_role.devopsshack_cluster_role.arn

  vpc_config {
    subnet_ids = concat(
      aws_subnet.public[*].id,
      aws_subnet.private[*].id
    )
    security_group_ids = [aws_security_group.devopsshack_cluster_sg.id]
  }

  depends_on = [aws_iam_role_policy_attachment.devopsshack_cluster_role_policy]
}

# ----------------------------------------------------
# EKS NODE GROUP
# ----------------------------------------------------
resource "aws_eks_node_group" "devopsshack" {
  cluster_name    = aws_eks_cluster.devopsshack.name
  node_group_name = "devopsshack-node-group"
  node_role_arn   = aws_iam_role.devopsshack_node_group_role.arn
  subnet_ids      = aws_subnet.private[*].id

  scaling_config {
    desired_size = 2
    max_size     = 2
    min_size     = 2
  }

  instance_types = ["t2.medium"]

  remote_access {
    ec2_ssh_key = var.ssh_key_name
    source_security_group_ids = [aws_security_group.devopsshack_node_sg.id]
  }

  depends_on = [
    aws_iam_role_policy_attachment.devopsshack_node_group_role_policy,
    aws_iam_role_policy_attachment.devopsshack_node_group_cni_policy,
    aws_iam_role_policy_attachment.devopsshack_node_group_registry_policy
  ]
}
