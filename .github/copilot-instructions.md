---
applyTo: "**"
description: >
  Project context for Arithmetic MCP Server — AWS resource names, endpoints,
  and deployment details. Applies to all files in this workspace.
---

## This Project Context

**Product**: Arithmetic MCP Server — FastMCP, Python 3.10, port 8000, `streamable-http` transport
**Region**: `us-east-1`

| AWS Service | Resource Name |
|---|---|
| **VPC** | `vpc-arithmetic-mcp-prod` — 10.0.0.0/16 |
| **Public Subnets** | `public-subnet-1` (10.0.1.0/24, us-east-1a) · `public-subnet-2` (10.0.2.0/24, us-east-1b) |
| **Private Subnets** | `private-subnet-1` (10.0.10.0/24, us-east-1a) · `private-subnet-2` (10.0.20.0/24, us-east-1b) |
| **Internet Gateway** | `igw-arithmetic-mcp` |
| **NAT Gateway** | in `public-subnet-1` (Elastic IP) |
| **ALB Security Group** | `sg-alb-arithmetic-mcp` — inbound 80/443 from internet |
| **ECS Security Group** | `sg-ecs-arithmetic-mcp` — inbound 8000 from ALB SG only |
| **ECR Repository** | `arithmetic-mcp` — tag immutability: disabled |
| **ACM Certificate** | (optional) — for HTTPS on port 443 |
| **Load Balancer** | `prod-mcp-alb` — internet-facing ALB |
| **Target Group** | `prod-mcp-tg` — HTTP:8000, target type: ip, health: `GET /healthcheck` |
| **ECS Cluster** | `prod-mcp-cluster` — Fargate, Container Insights enabled |
| **Task Definition** | `prod-arithmetic-mcp` — 0.25 vCPU, 512 MB, `UV_NO_CACHE=1` required |
| **ECS Service** | `prod-arithmetic-mcp-svc` — desired: 2 tasks, min: 2, max: 4, circuit breaker: on |
| **CloudWatch Log Group** | `/ecs/prod-arithmetic-mcp` — 30-day retention |
| **IAM Task Exec Role** | `prod-mcp-task-exec-role` |
| **IAM Task Role** | `prod-mcp-task-role` |
| **IAM Deploy Role** | `github-actions-deploy-role` — OIDC, for GitHub Actions |
| **ALB DNS** | `prod-mcp-alb-822248219.us-east-1.elb.amazonaws.com` |
| **Health endpoint** | `GET /healthcheck` → `{"status":"ok","service":"arithmetic-mcp"}` |
