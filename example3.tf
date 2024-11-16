# Configure the AWS provider
provider "aws" {
  region = "us-east-1"
}

# Create VPC
resource "aws_vpc" "main" {
  cidr_block = "10.0.0.0/16"
  
  tags = {
    Name = "Main VPC"
  }
}

# Create public subnets
resource "aws_subnet" "public" {
  count             = 2
  vpc_id            = aws_vpc.main.id
  cidr_block        = "10.0.${count.index + 1}.0/24"
  availability_zone = data.aws_availability_zones.available.names[count.index]
  
  tags = {
    Name = "Public Subnet ${count.index + 1}"
  }
}

# Create private subnets
resource "aws_subnet" "private" {
  count             = 4
  vpc_id            = aws_vpc.main.id
  cidr_block        = "10.0.${count.index + 10}.0/24"
  availability_zone = data.aws_availability_zones.available.names[count.index % 2]
  
  tags = {
    Name = "Private Subnet ${count.index + 1}"
  }
}

# Create Internet Gateway
resource "aws_internet_gateway" "main" {
  vpc_id = aws_vpc.main.id
  
  tags = {
    Name = "Main IGW"
  }
}

# Create NAT Gateway
resource "aws_nat_gateway" "main" {
  allocation_id = aws_eip.nat.id
  subnet_id     = aws_subnet.public[0].id
  
  tags = {
    Name = "Main NAT Gateway"
  }
}

# Elastic IP for NAT Gateway
resource "aws_eip" "nat" {
  vpc   = true
  count = 1
}

# Create security groups
resource "aws_security_group" "web" {
  name        = "Web Tier SG"
  description = "Security group for web tier"
  vpc_id      = aws_vpc.main.id

  ingress {
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

resource "aws_security_group" "app" {
  name        = "App Tier SG"
  description = "Security group for app tier"
  vpc_id      = aws_vpc.main.id

  ingress {
    from_port       = 8080
    to_port         = 8080
    protocol        = "tcp"
    security_groups = [aws_security_group.web.id]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

resource "aws_security_group" "db" {
  name        = "DB Tier SG"
  description = "Security group for database tier"
  vpc_id      = aws_vpc.main.id

  ingress {
    from_port       = 3306
    to_port         = 3306
    protocol        = "tcp"
    security_groups = [aws_security_group.app.id]
  }
}

# Create Aurora MySQL cluster
resource "aws_rds_cluster" "aurora_mysql" {
  cluster_identifier     = "aurora-mysql-cluster"
  engine                 = "aurora-mysql"
  engine_version         = "8.0.mysql_aurora.3.05.1"
  availability_zones     = data.aws_availability_zones.available.names
  database_name          = "mydb"
  master_username        = "admin"
  master_password        = "password123"
  backup_retention_period = 7
  preferred_backup_window = "02:00-03:00"
  vpc_security_group_ids = [aws_security_group.db.id]
  db_subnet_group_name   = aws_db_subnet_group.aurora.name
  
  serverlessv2_scaling_configuration {
    max_capacity = 16
    min_capacity = 0.5
  }
}

resource "aws_rds_cluster_instance" "aurora_mysql_instance" {
  count               = 2
  identifier          = "aurora-mysql-instance-${count.index}"
  cluster_identifier  = aws_rds_cluster.aurora_mysql.id
  instance_class      = "db.r7g.large"
  engine              = aws_rds_cluster.aurora_mysql.engine
  engine_version      = aws_rds_cluster.aurora_mysql.engine_version
}

resource "aws_db_subnet_group" "aurora" {
  name       = "aurora-subnet-group"
  subnet_ids = aws_subnet.private[*].id
}

# Create ElastiCache cluster
resource "aws_elasticache_cluster" "redis" {
  cluster_id           = "redis-cluster"
  engine               = "redis"
  node_type            = "cache.r7g.large"
  num_cache_nodes      = 1
  parameter_group_name = "default.redis6.x"
  port                 = 6379
  subnet_group_name    = aws_elasticache_subnet_group.redis.name
  security_group_ids   = [aws_security_group.app.id]
}

resource "aws_elasticache_subnet_group" "redis" {
  name       = "redis-subnet-group"
  subnet_ids = aws_subnet.private[*].id
}

# Create EC2 instances for web tier
resource "aws_instance" "web" {
  count         = 2
  ami           = "ami-0c55b159cbfafe1f0"  # Amazon Linux 2 AMI (adjust as needed)
  instance_type = "t3.micro"
  subnet_id     = aws_subnet.public[count.index].id
  vpc_security_group_ids = [aws_security_group.web.id]
  
  tags = {
    Name = "Web Server ${count.index + 1}"
  }
}

# Create EC2 instances for app tier
resource "aws_instance" "app" {
  count         = 2
  ami           = "ami-0c55b159cbfafe1f0"  # Amazon Linux 2 AMI (adjust as needed)
  instance_type = "t3.micro"
  subnet_id     = aws_subnet.private[count.index].id
  vpc_security_group_ids = [aws_security_group.app.id]
  
  tags = {
    Name = "App Server ${count.index + 1}"
  }
}

# Create Application Load Balancer
resource "aws_lb" "web" {
  name               = "web-alb"
  internal           = false
  load_balancer_type = "application"
  security_groups    = [aws_security_group.web.id]
  subnets            = aws_subnet.public[*].id
}

resource "aws_lb_target_group" "web" {
  name     = "web-tg"
  port     = 80
  protocol = "HTTP"
  vpc_id   = aws_vpc.main.id
}

resource "aws_lb_listener" "web" {
  load_balancer_arn = aws_lb.web.arn
  port              = "80"
  protocol          = "HTTP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.web.arn
  }
}

# Attach web instances to ALB target group
resource "aws_lb_target_group_attachment" "web" {
  count            = length(aws_instance.web)
  target_group_arn = aws_lb_target_group.web.arn
  target_id        = aws_instance.web[count.index].id
  port             = 80
}

# Output important information
output "alb_dns_name" {
  description = "DNS name of the Application Load Balancer"
  value       = aws_lb.web.dns_name
