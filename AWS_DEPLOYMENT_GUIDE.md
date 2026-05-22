# AWS ECS Deployment Guide - Arithmetic MCP Server
## Manual Step-by-Step Deployment (No Pipeline)

**Architecture Overview:**
```
Docker Image (ECR) → ECS Fargate Cluster → ALB (Application Load Balancer) → Auto Scaling
```

---

## PHASE 1: PREREQUISITES & FOUNDATION

### Step 1.1: Create or Prepare AWS Account
- [ ] Access AWS Console (console.aws.amazon.com)
- [ ] Note your **Account ID** (top-right menu)
- [ ] Choose **Region** (e.g., us-east-1, us-west-2)
- [ ] Note your **Region** for all subsequent steps

### Step 1.2: Create IAM Roles & Policies

#### A. Create ECS Task Execution Role
1. Navigate to **IAM** → **Roles** → **Create role**
2. Select **AWS service** → **Elastic Container Service**
3. Choose **ECS Task** as the use case
4. Attach policies:
   - `AmazonECSTaskExecutionRolePolicy` (predefined)
   - `CloudWatchLogsFullAccess` (for logs)
5. Name: `prod-mcp-task-exec-role` *(CloudFormation names it `${EnvironmentName}-mcp-task-exec-role`)*
6. Create role and **note the ARN**

#### B. Create ECS Task Role (for app permissions)
1. Create another role: **AWS service** → **ECS Task**
2. Attach policy:
   - (Optional: CloudWatchPutMetricAlarmFullAccess for monitoring)
3. Name: `prod-mcp-task-role` *(CloudFormation names it `${EnvironmentName}-mcp-task-role`)*
4. **Note the ARN**

#### C. Create IAM User for Manual Deployment (Optional but Recommended)
1. **IAM** → **Users** → **Create user**
2. Name: `arithmetic-mcp-deployer`
3. Attach policies:
   - `AmazonEC2ContainerRegistryFullAccess` (for ECR)
   - `AmazonECS_FullAccess` (for ECS)
   - `ElasticLoadBalancingFullAccess` (for ALB)
   - `AmazonEC2FullAccess` (for VPC/Security Groups)
4. Create **Access Key** for this user
5. **Note the Access Key ID and Secret**

### Step 1.3: Create CloudWatch Log Group
1. Navigate to **CloudWatch** → **Log Groups** → **Create log group**
2. Name: `/ecs/prod-arithmetic-mcp` *(CloudFormation names it `/ecs/${EnvironmentName}-arithmetic-mcp`)*
3. Retention: 30 days *(set to 7 days if cost-sensitive; CloudFormation default is 30)*
4. **Note the log group name**

---

## PHASE 2: NETWORK INFRASTRUCTURE

### Step 2.1: Create VPC
1. Navigate to **VPC** → **Your VPCs** → **Create VPC**
2. Configuration:
   - Name tag: `vpc-arithmetic-mcp-prod`
   - IPv4 CIDR block: `10.0.0.0/16`
   - IPv6: Disable (unless needed)
3. Create VPC

### Step 2.2: Create Subnets

#### Public Subnet 1
1. **VPC** → **Subnets** → **Create subnet**
2. VPC: `vpc-arithmetic-mcp-prod`
3. Subnet settings:
   - Name: `public-subnet-1`
   - Availability Zone: `us-east-1a` (choose your region)
   - IPv4 CIDR: `10.0.1.0/24`
4. Create subnet

#### Public Subnet 2
1. Create another subnet:
   - Name: `public-subnet-2`
   - AZ: `us-east-1b`
   - IPv4 CIDR: `10.0.2.0/24`

#### Private Subnet 1
1. Create subnet:
   - Name: `private-subnet-1`
   - AZ: `us-east-1a`
   - IPv4 CIDR: `10.0.10.0/24`

#### Private Subnet 2
1. Create subnet:
   - Name: `private-subnet-2`
   - AZ: `us-east-1b`
   - IPv4 CIDR: `10.0.20.0/24`

### Step 2.3: Create Internet Gateway
1. **VPC** → **Internet Gateways** → **Create internet gateway**
2. Name: `igw-arithmetic-mcp`
3. Create
4. **Attach to VPC**: Select the IGW → **Actions** → **Attach to VPC** → choose `vpc-arithmetic-mcp-prod`

### Step 2.4: Create NAT Gateway (for private subnet outbound)
1. **VPC** → **NAT Gateways** → **Create NAT gateway**
2. Subnet: `public-subnet-1`
3. Allocate Elastic IP
4. Create
5. **Note the NAT Gateway ID**

### Step 2.5: Create Route Tables

#### Public Route Table
1. **VPC** → **Route tables** → **Create route table**
2. Name: `rt-public-arithmetic-mcp`
3. VPC: `vpc-arithmetic-mcp-prod`
4. Add route:
   - Destination: `0.0.0.0/0`
   - Target: Internet Gateway (select your IGW)
5. **Associate with subnets**:
   - Associate → `public-subnet-1` and `public-subnet-2`

#### Private Route Table
1. Create another route table:
   - Name: `rt-private-arithmetic-mcp`
   - VPC: `vpc-arithmetic-mcp-prod`
2. Add route:
   - Destination: `0.0.0.0/0`
   - Target: NAT Gateway (select your NAT)
3. **Associate with subnets**:
   - Associate → `private-subnet-1` and `private-subnet-2`

### Step 2.6: Create Security Groups

#### ALB Security Group
1. **EC2** → **Security Groups** → **Create security group**
2. Name: `sg-alb-arithmetic-mcp`
3. Description: "ALB for Arithmetic MCP"
4. VPC: `vpc-arithmetic-mcp-prod`
5. Inbound rules:
   - Type: HTTP | Protocol: TCP | Port: 80 | Source: 0.0.0.0/0
   - Type: HTTPS | Protocol: TCP | Port: 443 | Source: 0.0.0.0/0
6. Outbound: Default (all traffic)

#### ECS Security Group
1. Create another security group:
   - Name: `sg-ecs-arithmetic-mcp`
   - Description: "ECS tasks for Arithmetic MCP"
   - VPC: `vpc-arithmetic-mcp-prod`
2. Inbound rules:
   - Type: Custom TCP | Port: 8000 | Source: `sg-alb-arithmetic-mcp` (select SG)
   - Type: All TCP | Port: any | Source: 10.0.0.0/16 (for inter-task communication)
3. Outbound: Default (all traffic)

---

## PHASE 3: CONTAINER REGISTRY (ECR)

### Step 3.1: Create ECR Repository
1. Navigate to **Elastic Container Registry** → **Repositories** → **Create repository**
2. Repository name: `arithmetic-mcp`
3. Image tag immutability: **Disable** ⚠️ — enabling this blocks re-pushing the `latest` tag on every deployment
4. Image scan on push: Enable
5. Encryption: AES256
6. Lifecycle policy (optional but recommended):
   ```json
   {
     "rules": [
       {
         "rulePriority": 1,
         "description": "Keep last 10 images",
         "selection": {
           "tagStatus": "any",
           "countType": "imageCountMoreThan",
           "countNumber": 10
         },
         "action": { "type": "expire" }
       }
     ]
   }
   ```
7. Create repository
8. **Note the Repository URI** (format: `ACCOUNT_ID.dkr.ecr.REGION.amazonaws.com/arithmetic-mcp`)

### Step 3.2: Push Docker Image to ECR

#### On your local machine (with Docker installed):

```bash
# 1. Authenticate Docker with ECR
aws ecr get-login-password --region us-east-1 | \
  docker login --username AWS --password-stdin ACCOUNT_ID.dkr.ecr.us-east-1.amazonaws.com

# 2. Build Docker image
docker build -t arithmetic-mcp:v1.0.0 .

# 3. Tag for ECR
docker tag arithmetic-mcp:v1.0.0 \
  ACCOUNT_ID.dkr.ecr.us-east-1.amazonaws.com/arithmetic-mcp:v1.0.0

# 4. Push to ECR
docker push ACCOUNT_ID.dkr.ecr.us-east-1.amazonaws.com/arithmetic-mcp:v1.0.0

# 5. Also push as latest
docker tag arithmetic-mcp:v1.0.0 \
  ACCOUNT_ID.dkr.ecr.us-east-1.amazonaws.com/arithmetic-mcp:latest
docker push ACCOUNT_ID.dkr.ecr.us-east-1.amazonaws.com/arithmetic-mcp:latest
```

**Note the full ECR image URI**: `ACCOUNT_ID.dkr.ecr.us-east-1.amazonaws.com/arithmetic-mcp:v1.0.0`

---

## PHASE 4: TLS CERTIFICATE (OPTIONAL but RECOMMENDED)

### Step 4.1: Request ACM Certificate (if using HTTPS)
1. Navigate to **AWS Certificate Manager** → **Request certificate**
2. Certificate type: **Public certificate**
3. Domain names: 
   - `yourdomain.com` (your ALB domain)
   - `*.yourdomain.com` (wildcard, optional)
4. Validation method: **DNS validation** (recommended)
5. Request certificate
6. After creation, verify DNS validation
7. **Note the Certificate ARN**

*Skip this if you're using HTTP-only for testing.*

---

## PHASE 5: APPLICATION LOAD BALANCER (ALB)

### Step 5.1: Create Load Balancer
1. Navigate to **EC2** → **Load Balancers** → **Create load balancer**
2. Choose **Application Load Balancer**
3. Configure Load Balancer:
   - Name: `prod-mcp-alb` *(CloudFormation names it `${EnvironmentName}-mcp-alb`)*
   - Scheme: Internet-facing
   - IP address type: IPv4
4. Network mapping:
   - VPC: `vpc-arithmetic-mcp-prod`
   - Subnets: Select `public-subnet-1` and `public-subnet-2`
5. Security Groups: Select `sg-alb-arithmetic-mcp`
6. Listener (HTTP):
   - Protocol: HTTP | Port: 80
   - Default action: Forward to target group (create new)
7. Create target group:
   - Name: `prod-mcp-tg` *(CloudFormation names it `${EnvironmentName}-mcp-tg`)*
   - Protocol: HTTP
   - Port: 8000
   - VPC: `vpc-arithmetic-mcp-prod`
   - Health check:
     - Path: `/health` (or `/`)
     - Interval: 30 seconds
     - Timeout: 5 seconds
     - Healthy threshold: 2
     - Unhealthy threshold: 3
   - Create target group
8. Finish creating ALB
9. **Note the ALB DNS name** (format: `alb-arithmetic-mcp-prod-1926413918.us-east-1.elb.amazonaws.com`)

### Step 5.2: Add HTTPS Listener (Optional)
1. Select the ALB → **Listeners** → **Add listener**
2. Protocol: HTTPS | Port: 443
3. Certificate: Select your ACM certificate
4. Default action: Forward to `tg-arithmetic-mcp`
5. Add listener

### Step 5.3: Add HTTP → HTTPS Redirect (Optional)
1. Edit the HTTP listener
2. Default action: Redirect
3. Protocol: HTTPS | Port: 443 | Status code: HTTP 301
4. Save

---

## PHASE 6: ECS CLUSTER & SERVICE

### Step 6.1: Create ECS Cluster
1. Navigate to **ECS** → **Clusters** → **Create cluster**
2. Cluster name: `prod-mcp-cluster` *(CloudFormation names it `${EnvironmentName}-mcp-cluster`)*
3. Infrastructure: **AWS Fargate** (serverless)
4. Default capacity provider: FARGATE
5. Create cluster

### Step 6.2: Create CloudWatch Log Group (if not done earlier)
1. **CloudWatch** → **Log Groups** → **Create log group**
2. Name: `/ecs/arithmetic-mcp/prod`
3. Retention: 7 days

### Step 6.3: Create ECS Task Definition
1. Navigate to **ECS** → **Task Definitions** → **Create new task definition**
2. Task Definition Family: `prod-arithmetic-mcp` *(CloudFormation names it `${EnvironmentName}-arithmetic-mcp`)*
3. Launch type: **Fargate**
4. Operating system: Linux
5. CPU: **0.25 vCPU** (256 units)
6. Memory: **0.5 GB** (512 MB)
7. Network mode: **awsvpc** (required for Fargate)
8. Task role: `ecsTaskRole-arithmetic-mcp`
9. Task execution role: `ecsTaskExecutionRole-arithmetic-mcp`

### Step 6.4: Add Container to Task Definition
1. Click **Add container** → **Add container**
2. Container details:
   - Name: `arithmetic-mcp`
   - Image URI: `ACCOUNT_ID.dkr.ecr.us-east-1.amazonaws.com/arithmetic-mcp:v1.0.0`
   - Essential: Yes
3. Port mappings:
   - Container port: 8000
   - Protocol: TCP
   - Name: `arithmetic-mcp`
   - App protocol: HTTP
4. Environment variables:
   - `PORT`: 8000
   - `HOST`: 0.0.0.0
   - `MCP_TRANSPORT`: streamable-http
   - `PYTHONUNBUFFERED`: 1
   - `UV_CACHE_DIR`: /tmp/.uv-cache
   - `UV_NO_CACHE`: 1  ← **Required** — prevents uv from writing to `/nonexistent/.cache/uv` (Debian system user home issue)
5. Logging - CloudWatch:
   - Log driver: awslogs
   - Log group: `/ecs/prod-arithmetic-mcp`
   - Log stream prefix: `ecs`
   - Region: us-east-1
6. Health check:
   - Command: `CMD, python, -c, import socket,sys;s=socket.socket();s.settimeout(5);r=s.connect_ex(('127.0.0.1',8000));s.close();sys.exit(r)`
   - **Note**: Do NOT use `curl` — it is not installed in the `python:3.10-slim` base image
   - Interval: 30 seconds
   - Timeout: 10 seconds
   - Start period: 60 seconds
   - Retries: 3
7. Add container and **Create task definition**

### Step 6.5: Create ECS Service
1. Navigate to **ECS** → **Clusters** → `arithmetic-mcp-prod`
2. Create service:
   - Launch type: Fargate
   - Service name: `prod-arithmetic-mcp-svc` *(CloudFormation names it `${EnvironmentName}-arithmetic-mcp-svc`)*
   - Desired number of tasks: 2 (for HA)
   - Task definition: `arithmetic-mcp-td` (latest)
3. Networking:
   - VPC: `vpc-arithmetic-mcp-prod`
   - Subnets: `private-subnet-1` and `private-subnet-2`
   - Security groups: `sg-ecs-arithmetic-mcp`
   - Public IP: DISABLED (tasks in private subnets)
4. Load balancing:
   - Load balancer type: Application Load Balancer
   - Load balancer: `alb-arithmetic-mcp-prod`
   - Container: `arithmetic-mcp`
   - Port: 8000
   - Target group: `tg-arithmetic-mcp`
5. Auto Scaling (optional but recommended):
   - Enable service autoscaling
   - Min capacity: 2
   - Max capacity: 4
   - Scaling policy: Target tracking
   - Target metric: CPU utilization
   - Target value: 70%
6. Create service

### Step 6.6: Verify Service is Running
1. **ECS** → **Clusters** → `arithmetic-mcp-prod` → **Services** → `arithmetic-mcp-service`
2. Check:
   - Tasks tab: Should show 2 running tasks (green)
   - Logs: Check CloudWatch logs
3. Wait 2-3 minutes for tasks to stabilize

---

## PHASE 7: AUTO SCALING CONFIGURATION

### Step 7.1: Create Target Tracking Scaling Policy
1. **ECS** → **Clusters** → `arithmetic-mcp-prod` → **Services** → `arithmetic-mcp-service`
2. Auto Scaling section:
   - Service autoscaling: Enabled
   - Min: 2 tasks
   - Max: 4 tasks
   - Scaling policy: Target tracking
   - Metric: CPU utilization or Request count per target
   - Target value: 70% (for CPU)
3. Save

### Step 7.2: (Optional) Add Scheduled Scaling
1. **Application Auto Scaling** → **Scheduled actions**
2. Create scheduled action (e.g., scale up during business hours)

---

## PHASE 8: TESTING & VALIDATION

### Step 8.1: Get ALB Endpoint
1. **EC2** → **Load Balancers** → `alb-arithmetic-mcp-prod`
2. Copy DNS name (format: `alb-arithmetic-mcp-prod-1926413918.us-east-1.elb.amazonaws.com`)

### Step 8.2: Test the Service

> **Important**: The ALB listens on port **80** (redirects to 443) and **443 (HTTPS)** only.
> Do NOT include `:8000` in the URL — that is the internal container port, not the ALB listener port.
> Port 80 returns HTTP 301 → HTTPS. Use `-L` to follow the redirect, or test HTTPS directly.
> In PowerShell, use `curl.exe` (not `curl` which aliases to `Invoke-WebRequest`).

```bash
# Health check (HTTP → follows redirect to HTTPS)
curl -L http://alb-arithmetic-mcp-prod-1926413918.us-east-1.elb.amazonaws.com/health

# Health check (HTTPS directly — requires valid certificate)
curl https://alb-arithmetic-mcp-prod-1926413918.us-east-1.elb.amazonaws.com/health

# Initialize MCP session
curl -X POST https://alb-arithmetic-mcp-prod-1926413918.us-east-1.elb.amazonaws.com/mcp \
  -H "Content-Type: application/json" \
  -H "Accept: application/json, text/event-stream" \
  -d '{"jsonrpc":"2.0","id":0,"method":"initialize","params":{"protocolVersion":"2024-11-05","capabilities":{},"clientInfo":{"name":"test","version":"1.0"}}}'

# Call the add tool (replace SESSION_ID from initialize response header mcp-session-id)
curl -X POST https://alb-arithmetic-mcp-prod-1926413918.us-east-1.elb.amazonaws.com/mcp \
  -H "Content-Type: application/json" \
  -H "Accept: application/json, text/event-stream" \
  -H "mcp-session-id: SESSION_ID" \
  -d '{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"add","arguments":{"a":10,"b":5}}}'
```

### Step 8.3: Monitor CloudWatch Logs
1. **CloudWatch** → **Log Groups** → `/ecs/prod-arithmetic-mcp`
2. View recent log streams
3. Check for errors

---

## PHASE 9: DNS & DOMAIN SETUP (OPTIONAL)

### Step 9.1: Point Domain to ALB
1. **Route 53** → **Hosted Zones** → Your domain
2. Create record:
   - Name: `mcp.yourdomain.com` (or subdomain)
   - Type: A
   - Alias: Yes
   - Alias target: Select ALB
   - Routing policy: Simple
   - Create record
3. Wait 5-10 minutes for DNS propagation

### Step 9.2: Verify Domain Access
```bash
curl http://mcp.yourdomain.com/health
```

---

## PHASE 10: MONITORING & MAINTENANCE

### Step 10.1: Create CloudWatch Dashboards
1. **CloudWatch** → **Dashboards** → **Create dashboard**
2. Name: `arithmetic-mcp-prod`
3. Add widgets:
   - ECS Service CPU utilization
   - ECS Service memory utilization
   - ALB active connection count
   - ALB request count
   - Target group healthy/unhealthy hosts

### Step 10.2: Set Up Alarms
1. **CloudWatch** → **Alarms** → **Create alarm**
2. Metric: ECS CPU > 80%
3. Action: SNS notification (optional)
4. Repeat for memory, unhealthy hosts, etc.

### Step 10.3: Review Logs Regularly
- **CloudWatch** → **Insights** → Query logs for errors

---

## TROUBLESHOOTING REFERENCE

| Issue | Solution |
|-------|----------|
| Tasks not running | Check CloudWatch logs, verify task definition, check IAM roles |
| ALB not routing to tasks | Verify SG rules, target health check, task network settings |
| High latency | Check task CPU/memory, consider scaling up |
| Tasks keep restarting | Check health check settings, container logs |
| Cannot reach ALB | Verify ALB SG allows port 80/443, public subnets route to IGW |

---

## COST ESTIMATION

**Monthly cost (approximate):**
- ECS Fargate: 2 tasks × 0.25 vCPU × $0.04/hour × 730 hours = ~$58
- ALB: ~$22 (fixed) + data charges
- NAT Gateway: ~$45 + data charges
- CloudWatch Logs: ~$5-10 depending on volume
- **Total: ~$130-180/month**

---

## CHECKLIST - DEPLOYMENT COMPLETION

- [ ] VPC created with public/private subnets
- [ ] Security groups configured
- [ ] ECR repository created & image pushed
- [ ] ALB created & configured
- [ ] Target group health checks passing
- [ ] ECS cluster created
- [ ] Task definition created
- [ ] ECS service running with 2+ tasks
- [ ] ALB endpoint responding to requests
- [ ] CloudWatch logs showing normal operation
- [ ] Auto scaling policies configured
- [ ] Alarms set up
- [ ] DNS pointing to ALB (if applicable)
- [ ] Documentation updated

---

## NEXT STEPS

1. **Backup Configuration**: Export your CloudFormation template
2. **CI/CD Pipeline**: Implement pipeline for automated deployments
3. **API Gateway**: Add API Gateway in front of ALB for advanced routing
4. **WAF**: Add AWS WAF to ALB for security
5. **Performance**: Run load tests and optimize task sizing
