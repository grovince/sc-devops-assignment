# ---------------------------------------------------------------------------
# VPC
#
# enable_dns_hostnames는 Interface Endpoint의 private DNS 동작에 필수다.
# 비활성 상태면 기본 도메인이 엔드포인트 사설 IP로 해석되지 않아
# 애플리케이션이 엔드포인트 전용 DNS를 직접 지정해야 한다.
# ---------------------------------------------------------------------------
resource "aws_vpc" "this" {
  cidr_block           = var.vpc_cidr
  enable_dns_support   = true
  enable_dns_hostnames = true

  tags = { Name = "${var.name}-vpc" }
}

resource "aws_internet_gateway" "this" {
  vpc_id = aws_vpc.this.id
  tags   = { Name = "${var.name}-igw" }
}

# ---------------------------------------------------------------------------
# 서브넷 3계층 x 3AZ
#
#   퍼블릭   : ALB. 인터넷에서 직접 접근 가능한 유일한 계층
#   앱       : Fargate 태스크 + Interface Endpoint ENI
#   데이터   : MSK 브로커. 앱 계층과 분리하여 SG/NACL 경계를 한 겹 더 둔다
# ---------------------------------------------------------------------------
resource "aws_subnet" "public" {
  count = length(var.azs)

  vpc_id            = aws_vpc.this.id
  cidr_block        = var.public_subnet_cidrs[count.index]
  availability_zone = var.azs[count.index]

  # ALB ENI는 AWS가 퍼블릭 IP를 할당한다. 태스크가 배치되지 않으므로 자동 할당 불필요
  map_public_ip_on_launch = false

  tags = {
    Name = "${var.name}-public-${var.azs[count.index]}"
    Tier = "public"
  }
}

resource "aws_subnet" "app" {
  count = length(var.azs)

  vpc_id            = aws_vpc.this.id
  cidr_block        = var.app_subnet_cidrs[count.index]
  availability_zone = var.azs[count.index]

  tags = {
    Name = "${var.name}-app-${var.azs[count.index]}"
    Tier = "private-app"
  }
}

resource "aws_subnet" "data" {
  count = length(var.azs)

  vpc_id            = aws_vpc.this.id
  cidr_block        = var.data_subnet_cidrs[count.index]
  availability_zone = var.azs[count.index]

  tags = {
    Name = "${var.name}-data-${var.azs[count.index]}"
    Tier = "private-data"
  }
}

# ---------------------------------------------------------------------------
# 라우팅
#
# 프라이빗 라우팅 테이블에는 0.0.0.0/0 경로가 존재하지 않는다.
# NAT Gateway 대신 VPC Endpoint로 아웃바운드를 대체했기 때문이며,
# 그 결과 프라이빗 서브넷에서 인터넷으로 나가는 경로가 물리적으로 없다.
#
# 프라이빗 테이블을 AZ별로 분리한 이유:
# 현재는 로컬 경로뿐이라 공유해도 무방하지만, 향후 NAT를 재도입할 경우
# AZ별 NAT를 지정하려면 테이블이 분리되어 있어야 한다.
# ---------------------------------------------------------------------------
resource "aws_route_table" "public" {
  vpc_id = aws_vpc.this.id
  tags   = { Name = "${var.name}-rt-public" }
}

resource "aws_route" "public_internet" {
  route_table_id         = aws_route_table.public.id
  destination_cidr_block = "0.0.0.0/0"
  gateway_id             = aws_internet_gateway.this.id
}

resource "aws_route_table_association" "public" {
  count          = length(var.azs)
  subnet_id      = aws_subnet.public[count.index].id
  route_table_id = aws_route_table.public.id
}

resource "aws_route_table" "private" {
  count = length(var.azs)

  vpc_id = aws_vpc.this.id
  tags   = { Name = "${var.name}-rt-private-${var.azs[count.index]}" }
}

resource "aws_route_table_association" "app" {
  count          = length(var.azs)
  subnet_id      = aws_subnet.app[count.index].id
  route_table_id = aws_route_table.private[count.index].id
}

resource "aws_route_table_association" "data" {
  count          = length(var.azs)
  subnet_id      = aws_subnet.data[count.index].id
  route_table_id = aws_route_table.private[count.index].id
}

# ---------------------------------------------------------------------------
# Flow Logs
# REJECT만 기록하여 비용을 절감한다. 침입 시도 탐지에는 충분하다.
# ---------------------------------------------------------------------------
resource "aws_flow_log" "this" {
  count = var.flow_log_bucket_arn == "" ? 0 : 1

  vpc_id               = aws_vpc.this.id
  traffic_type         = "REJECT"
  log_destination_type = "s3"
  log_destination      = var.flow_log_bucket_arn

  tags = { Name = "${var.name}-flowlog" }
}
