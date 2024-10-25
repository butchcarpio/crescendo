variable "public_subnets" {
  description = "A list of subnet attributes, with a map of values"
  type        = list(map(string))
  default     = [
  { 
    name                    = "crescendo-public-1"
    cidr_block              = "10.0.1.0/24"
    availability_zone       = "us-east-1a"
    map_public_ip_on_launch = true
  },
  {
    name                    = "crescendo-public-2"
    cidr_block              = "10.0.2.0/24"
    availability_zone       = "us-east-1b"
    map_public_ip_on_launch = true
  },
]
}

variable "private_subnets" {
  description = "A list of subnet attributes, with a map of values"
  type        = list(map(string))
  default     = [
  {
    name                    = "crescendo-private-1"
    cidr_block              = "10.0.3.0/24"
    availability_zone       = "us-east-1a"
  },
  {
    name                    = "crescendo-private-2"
    cidr_block              = "10.0.4.0/24"
    availability_zone       = "us-east-1b"
  },
]
}