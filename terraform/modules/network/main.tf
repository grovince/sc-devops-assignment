terraform {
  required_version = ">= 1.5.0"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 5.0"
    }
  }
}

# ---------------------------------------------------------------------------
# 가용 영역 조회
# ---------------------------------------------------------------------------

data "aws_availability_zones" "available" {
  state = "available"

  # opt-in이 필요한 AZ는 제외한다.
  filter {
    name   = "opt-in-status"
    values = ["opt-in-not-required"]
  }
}

locals {
  azs = slice(data.aws_availability_zones.available.names, 0, var.az_count)

  # 10.0.0.0/24, 10.0.1.0/24, 10.0.2.0/24 ...
  public_cidrs = [for i in range(var.az_count) : cidrsubnet(var.vpc_cidr, 8, i)]

  # 10.0.10.0/24, 10.0.11.0/24, 10.0.12.0/24 ...
  private_cidrs = [for i in range(var.az_count) : cidrsubnet(var.vpc_cidr, 8, i + 10)]

  # Interface Endpoint는 지정한 서브넷마다 ENI를 생성한다.
  # 아래 서비스들은 Interface 방식으로만 제공된다.
  # Gateway Endpoint는 S3와 DynamoDB 두 서비스만 지원하기 때문이다.
  #
  #   kinesis-streams : API 서버의 PutRecords 호출
  #   ecr.api         : ECR 인증 및 이미지 메타데이터
  #   ecr.dkr         : 이미지 pull을 위한 Docker Registry 프로토콜
  #   logs            : awslogs 드라이버의 컨테이너 stdout 전송
  interface_services = [
    "kinesis-streams",
    "ecr.api",
    "ecr.dkr",
    "logs",
  ]
}

# ---------------------------------------------------------------------------
# VPC
# ---------------------------------------------------------------------------

resource "aws_vpc" "this" {
  cidr_block = var.vpc_cidr

  # Interface Endpoint가 프라이빗 IP로 해석되려면 두 옵션이 모두 필요하다.
  enable_dns_support   = true
  enable_dns_hostnames = true

  tags = {
    Name = "${var.name_prefix}-vpc"
  }
}

resource "aws_internet_gateway" "this" {
  vpc_id = aws_vpc.this.id

  tags = {
    Name = "${var.name_prefix}-igw"
  }
}

# ---------------------------------------------------------------------------
# 서브넷
# ---------------------------------------------------------------------------

resource "aws_subnet" "public" {
  count = var.az_count

  vpc_id                  = aws_vpc.this.id
  cidr_block              = local.public_cidrs[count.index]
  availability_zone       = local.azs[count.index]
  map_public_ip_on_launch = true

  tags = {
    Name = "${var.name_prefix}-public-${local.azs[count.index]}"
    Tier = "public"
  }
}

resource "aws_subnet" "private" {
  count = var.az_count

  vpc_id            = aws_vpc.this.id
  cidr_block        = local.private_cidrs[count.index]
  availability_zone = local.azs[count.index]

  # 퍼블릭 IP를 부여하지 않는다. 외부 통신은 NAT Gateway가 아니라
  # VPC 엔드포인트를 통해서만 이루어진다.
  map_public_ip_on_launch = false

  tags = {
    Name = "${var.name_prefix}-private-${local.azs[count.index]}"
    Tier = "private"
  }
}

# ---------------------------------------------------------------------------
# 라우트 테이블
#
# Public  : Internet Gateway로 향하는 기본 경로를 가진다.
# Private : local 경로만 가진다. NAT Gateway를 의도적으로 두지 않았으므로
#           프라이빗 서브넷에는 인터넷으로 나가는 경로가 존재하지 않는다.
#           모든 AWS 서비스 접근은 아래 VPC 엔드포인트를 경유한다.
# ---------------------------------------------------------------------------

resource "aws_route_table" "public" {
  vpc_id = aws_vpc.this.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.this.id
  }

  tags = {
    Name = "${var.name_prefix}-rt-public"
  }
}

resource "aws_route_table_association" "public" {
  count = var.az_count

  subnet_id      = aws_subnet.public[count.index].id
  route_table_id = aws_route_table.public.id
}

# 프라이빗 라우트 테이블은 AZ별로 분리한다. S3 Gateway Endpoint 연결과
# 향후 AZ별 라우팅 변경을 서로 독립적으로 다루기 위함이다.
resource "aws_route_table" "private" {
  count = var.az_count

  vpc_id = aws_vpc.this.id

  tags = {
    Name = "${var.name_prefix}-rt-private-${local.azs[count.index]}"
  }
}

resource "aws_route_table_association" "private" {
  count = var.az_count

  subnet_id      = aws_subnet.private[count.index].id
  route_table_id = aws_route_table.private[count.index].id
}

# ---------------------------------------------------------------------------
# VPC 엔드포인트용 보안 그룹
#
# security 모듈이 아니라 이곳에서 만드는 이유는 모듈 간 순환 참조를 피하기
# 위해서다. 아래 엔드포인트들은 생성 시점에 이 보안 그룹의 ID가 필요하고,
# security 모듈은 이 VPC의 ID가 필요하다.
#
# 여기서는 규칙 없는 빈 보안 그룹만 만들고, ECS 태스크로부터 443을 허용하는
# 인그레스 규칙은 security 모듈이 붙인다.
# ---------------------------------------------------------------------------

resource "aws_security_group" "vpc_endpoints" {
  name        = "${var.name_prefix}-vpce-sg"
  description = "VPC Interface Endpoint ENI에 부착되는 보안 그룹"
  vpc_id      = aws_vpc.this.id

  tags = {
    Name = "${var.name_prefix}-vpce-sg"
  }

  lifecycle {
    create_before_destroy = true
  }
}

# ---------------------------------------------------------------------------
# Interface Endpoint (AWS PrivateLink)
# ---------------------------------------------------------------------------

resource "aws_vpc_endpoint" "interface" {
  for_each = toset(local.interface_services)

  vpc_id            = aws_vpc.this.id
  service_name      = "com.amazonaws.${var.region}.${each.value}"
  vpc_endpoint_type = "Interface"

  subnet_ids         = aws_subnet.private[*].id
  security_group_ids = [aws_security_group.vpc_endpoints.id]

  # 이 옵션이 없으면 서비스 도메인이 여전히 퍼블릭 IP로 해석되어
  # 트래픽이 엔드포인트를 타지 않는다.
  private_dns_enabled = true

  tags = {
    Name = "${var.name_prefix}-vpce-${replace(each.value, ".", "-")}"
  }
}

# ---------------------------------------------------------------------------
# S3 Gateway Endpoint
#
# 무료이며 ENI가 아니라 라우트 테이블 항목으로 동작한다.
# ECR이 이미지 레이어를 S3에 저장하므로, NAT Gateway가 없는 서브넷에서는
# 이 엔드포인트가 없으면 이미지 pull 자체가 실패한다.
# ---------------------------------------------------------------------------

resource "aws_vpc_endpoint" "s3" {
  vpc_id            = aws_vpc.this.id
  service_name      = "com.amazonaws.${var.region}.s3"
  vpc_endpoint_type = "Gateway"

  route_table_ids = aws_route_table.private[*].id

  tags = {
    Name = "${var.name_prefix}-vpce-s3"
  }
}
