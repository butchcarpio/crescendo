terraform {
  backend "s3" {
    bucket  = "crescendo.butch.tf.state"
    region  = "us-east-1"
    key     = "infra/cresendo.tfstate"
    encrypt = true
    acl     = "bucket-owner-full-control"
  }

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 3.21.0"
    }
  }
  required_version = ">= 1.7.5"
}

locals {
  public_subnets  = { for public_subnets in var.public_subnets : public_subnets.cidr_block => public_subnets }
  private_subnets = { for private_subnets in var.private_subnets : private_subnets.cidr_block => private_subnets }
}

#VPC
resource "aws_vpc" "main" {
  cidr_block = "10.0.0.0/16"
  tags = {
    Name = "Crescendo-Butch"
  }
}

#PUBLIC SUBNETS
resource "aws_subnet" "crescendo-public-subnets" {
  for_each                = local.public_subnets
  vpc_id                  = aws_vpc.main.id
  cidr_block              = each.value.cidr_block
  availability_zone       = each.value.availability_zone
  map_public_ip_on_launch = true
  tags = {
    Name = each.value.name
  }
}

#PRIVATE SUBNETS
resource "aws_subnet" "crescendo-private-subnets" {
  for_each          = local.private_subnets
  vpc_id            = aws_vpc.main.id
  cidr_block        = each.value.cidr_block
  availability_zone = each.value.availability_zone
  tags = {
    Name = each.value.name
  }
}

#ALB
resource "aws_lb" "main" {
  name               = "crescendo-alb"
  internal           = false
  load_balancer_type = "application"
  security_groups    = [aws_security_group.allow_http.id]
  subnets            = [for subnet in aws_subnet.crescendo-private-subnets : subnet.id]

  enable_deletion_protection = false

}

resource "aws_eip" "nat-eip" {
  domain = "vpc"
  tags = {
    Name = "Crescendo-Butch"
  }
}

resource "aws_nat_gateway" "nat-gw" {
  allocation_id = aws_eip.nat-eip.id
  subnet_id     = aws_subnet.crescendo-public-subnets["10.0.1.0/24"].id
  tags = {
    Name = "Crescendo-Butch"
  }
}

resource "aws_route_table" "private" {
  vpc_id = aws_vpc.main.id
  tags = {
    Name = "Crescendo-Butch"
  }
}

resource "aws_route" "private_nat_gateway" {
  route_table_id         = aws_route_table.private.id
  destination_cidr_block = "0.0.0.0/0"
  nat_gateway_id         = aws_nat_gateway.nat-gw.id
}

resource "aws_route_table_association" "private" {
  subnet_id      = aws_subnet.crescendo-private-subnets["10.0.3.0/24"].id
  route_table_id = aws_route_table.private.id
}

resource "aws_internet_gateway" "igw" {
  vpc_id = aws_vpc.main.id

  tags = {
    Name = "crescendo-igw"
  }
}

resource "aws_route_table" "public" {
  vpc_id = aws_vpc.main.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.igw.id
  }

  tags = {
    Name = "public-route-table"
  }
}

resource "aws_route_table_association" "public" {
  subnet_id      = aws_subnet.crescendo-public-subnets["10.0.1.0/24"].id
  route_table_id = aws_route_table.public.id
}

#EC2
resource "aws_instance" "magnolia" {
  ami             = "ami-0866a3c8686eaeeba"
  instance_type   = "t2.micro"
  subnet_id       = aws_subnet.crescendo-public-subnets["10.0.1.0/24"].id
  security_groups = [aws_security_group.allow_http.id]
  key_name        = "butch"

  user_data = <<-EOF
              #!/bin/bash
              # Update the package list
              sudo apt-get update -y
              sudo apt-get install unzip
              sudo apt-get install openjdk-11-jdk -y
              sudo wget https://nexus.magnolia-cms.com/repository/public/info/magnolia/bundle/magnolia-community-demo-webapp/6.2.51/magnolia-community-demo-webapp-6.2.51-tomcat-bundle.zip
              sudo unzip magnolia-community-demo-webapp-6.2.51-tomcat-bundle.zip
              cd magnolia-6.2.51/apache-tomcat-9.0.96/bin/
              sudo ./magnolia_control.sh start --ignore-open-files-limit 
              sudo apt-get install nginx -y
              sudo rm /etc/nginx/sites-enabled/default 

              cd /etc/nginx/sites-available/
              sudo bash -c 'cat > default <<-EOM
              server {
                  listen 80;
                  server_name example.com;

                  location / {
                      proxy_set_header   X-Forwarded-For \$remote_addr;
                      proxy_set_header   Host \$http_host;
                      proxy_pass         "http://127.0.0.1:8080";
                  }
              }
              EOM'

              sudo ln -s /etc/nginx/sites-available/default /etc/nginx/sites-enabled/default
              sudo systemctl restart nginx
              EOF

  tags = {
    Name = "magnolia-instance"
  }

}

#CLOUDFRONT
resource "aws_s3_bucket" "crescendo-s3" {
  bucket = "crescendo-butch"

  tags = {
    Name = "crescendo-butch"
  }
}

resource "aws_cloudfront_origin_access_identity" "crescendo-OAI" {
  comment = "crescendo-s3 OAI"
}

resource "aws_cloudfront_distribution" "crescendo-distribution" {
  origin {
    domain_name = aws_s3_bucket.crescendo-s3.bucket_regional_domain_name
    origin_id   = "crescendo-s3-bucket"

    s3_origin_config {
      origin_access_identity = aws_cloudfront_origin_access_identity.crescendo-OAI.cloudfront_access_identity_path
    }
  }

  enabled             = true
  is_ipv6_enabled     = true
  comment             = "CloudFront distribution"
  default_root_object = "index.html"

  default_cache_behavior {
    allowed_methods  = ["GET", "HEAD"]
    cached_methods   = ["GET", "HEAD"]
    target_origin_id = "crescendo-s3-bucket"

    forwarded_values {
      query_string = false
      cookies {
        forward = "none"
      }
    }

    viewer_protocol_policy = "redirect-to-https"
    min_ttl                = 0
    default_ttl            = 3600
    max_ttl                = 86400
  }

  restrictions {
    geo_restriction {
      restriction_type = "none"
    }
  }

  viewer_certificate {
    cloudfront_default_certificate = true
  }

  tags = {
    Name = "crescendo-butch-distribution"
  }
}

#SECURITY GROUPS
resource "aws_security_group" "allow_http" {
  name        = "web_access"
  description = "Allow inbound HTTP traffic"
  vpc_id      = aws_vpc.main.id

  ingress {
    description      = "Allow HTTP from anywhere"
    from_port        = 80
    to_port          = 80
    protocol         = "tcp"
    cidr_blocks      = ["0.0.0.0/0"]
    ipv6_cidr_blocks = ["::/0"]
  }
  ingress {
    description      = "Allow HTTP from anywhere"
    from_port        = 8080
    to_port          = 8080
    protocol         = "tcp"
    cidr_blocks      = ["0.0.0.0/0"]
    ipv6_cidr_blocks = ["::/0"]
  }
  egress {
    from_port        = 0
    to_port          = 0
    protocol         = "-1"
    cidr_blocks      = ["0.0.0.0/0"]
    ipv6_cidr_blocks = ["::/0"]
  }

  tags = {
    Name = "allow_web"
  }
}