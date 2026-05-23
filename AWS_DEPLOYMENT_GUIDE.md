# AWS ECS Deployment Guide - Arithmetic MCP Server
## Manual Step-by-Step Deployment (No Pipeline)

---

## ARCHITECTURE OVERVIEW

### Component Hierarchy
```
ECS Cluster: prod-mcp-cluster  (Fargate — no EC2 to manage)
  └── ECS Service: prod-arithmetic-mcp-svc
        │  Maintains desired count | Rolling deploys | Auto-registers task IPs to Target Group
        │  Task Definition: prod-arithmetic-mcp  (versioned blueprint: image, CPU, mem, env)
        │
        ├── Task 1 (Fargate container instance)   [Private Subnet A: 10.0.10.x, us-east-1a]
        │   └── Container: arithmetic-mcp
        │       Image : <ACCOUNT>.dkr.ecr.us-east-1.amazonaws.com/arithmetic-mcp:tag
        │       Port  : 8000  |  CPU: 0.25 vCPU  |  Mem: 512 MB
        │       Env   : MCP_TRANSPORT=streamable-http, UV_NO_CACHE=1
        │
        └── Task 2 (Fargate container instance)   [Private Subnet B: 10.0.20.x, us-east-1b]
            └── Container: arithmetic-mcp
                Image : <ACCOUNT>.dkr.ecr.us-east-1.amazonaws.com/arithmetic-mcp:tag
                Port  : 8000  |  CPU: 0.25 vCPU  |  Mem: 512 MB
                Env   : MCP_TRANSPORT=streamable-http, UV_NO_CACHE=1
```

### Full Traffic & Network Flow
```
INTERNET (0.0.0.0/0)
   │  port 80  → Forward to Target Group  (→ Redirect 301→HTTPS after Step 5.3)
   │  port 443 → Forward to Target Group  (HTTPS — requires ACM certificate, Phase 4)
   ▼
ALB: prod-mcp-alb  (internet-facing)           [PUBLIC SUBNETS: us-east-1a + us-east-1b]
SG: sg-alb-arithmetic-mcp  (inbound 80+443; outbound port 8000 to ECS SG only)
   │
Target Group: prod-mcp-tg
Protocol: HTTP | Port: 8000 | Target type: ip  ← REQUIRED for Fargate awsvpc mode
Health check: GET /healthcheck → HTTP 200 (every 30 s)
   │
   ├── Task 1 private IP:8000 ─┐  auto-registered by ECS Service when task starts
   └── Task 2 private IP:8000 ─┘  auto-deregistered when task stops (deploy/crash/scale-in)
         │
   [PRIVATE SUBNETS — no public IP assigned to tasks]
   SG: sg-ecs-arithmetic-mcp  (inbound port 8000 from ALB SG only)
         │ outbound only (ECR image pull, CloudWatch log delivery)
         ▼
   NAT Gateway  [PUBLIC SUBNET — Elastic IP]
         │
         ├──→ ECR: arithmetic-mcp          (Docker image store)
         └──→ CloudWatch Logs: /ecs/prod-arithmetic-mcp  (30-day retention)

VPC: vpc-arithmetic-mcp-prod (10.0.0.0/16)
├── Public  Subnet A: 10.0.1.0/24  (us-east-1a)  ALB + NAT Gateway → Internet Gateway
├── Public  Subnet B: 10.0.2.0/24  (us-east-1b)  ALB               → Internet Gateway
├── Private Subnet A: 10.0.10.0/24 (us-east-1a)  ECS Tasks          → NAT Gateway
└── Private Subnet B: 10.0.20.0/24 (us-east-1b)  ECS Tasks          → NAT Gateway
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
   - `AmazonECSTaskExecutionRolePolicy` (predefined — covers ECR pull AND CloudWatch Logs)
   - **Do NOT** add `CloudWatchLogsFullAccess` — it is overly permissive and already covered above
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
6. Outbound rules (two options — pick one):
   - **Option A (Recommended / secure)**: Restrict to ECS only
     1. Delete the default `All traffic | 0.0.0.0/0` outbound rule first
     2. Add: `Custom TCP | TCP | Port: 8000 | Destination: sg-ecs-arithmetic-mcp`
     - ⚠️ You must delete the default rule first — AWS blocks mixing a CIDR rule with a SG-reference rule
   - **Option B (Simpler)**: Keep default `All traffic | 0.0.0.0/0` outbound — ALB works fine with this

#### ECS Security Group
1. Create another security group:
   - Name: `sg-ecs-arithmetic-mcp`
   - Description: "ECS tasks for Arithmetic MCP"
   - VPC: `vpc-arithmetic-mcp-prod`
2. Inbound rules:
   - Type: Custom TCP | Port: 8000 | Source: `sg-alb-arithmetic-mcp` (select SG)
   - **Do NOT add** an "All TCP from VPC CIDR" rule — ECS tasks only need to receive from the ALB
3. Outbound: All traffic (required for ECR image pull and CloudWatch logs via NAT Gateway)

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

*Phase 4 (TLS Certificate) is **required** for HTTPS. The infrastructure is designed with HTTP → HTTPS redirect on port 80 and HTTPS-only forwarding to ECS on port 443. Skip only for local/VPC-internal testing.*

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
   - Default action: **Forward to target group** `prod-mcp-tg`
   - ℹ️ Keep as Forward for now — update to Redirect in Step 5.3 AFTER HTTPS listener is set up (Step 5.2)
7. Create target group:
   - Name: `prod-mcp-tg` *(CloudFormation names it `${EnvironmentName}-mcp-tg`)*
   - Protocol: HTTP
   - Port: 8000
   - **Target type: `ip`** ← **Required for Fargate** (awsvpc network mode) — NOT `instance`
   - VPC: `vpc-arithmetic-mcp-prod`
   - Health check:
     - Path: `/healthcheck`
     - Healthy HTTP codes: `200`
     - Interval: 30 seconds
     - Timeout: **10 seconds**
     - Healthy threshold: 2
     - Unhealthy threshold: 3
   - Create target group
8. Finish creating ALB
9. **Note the ALB DNS name** (format: `alb-arithmetic-mcp-prod-1926413918.us-east-1.elb.amazonaws.com`)

### Step 5.2: Add HTTPS Listener (Recommended for production)
1. Select the ALB → **Listeners** → **Add listener**
2. Protocol: HTTPS | Port: 443
3. Certificate: Select your ACM certificate (Phase 4)
4. Default action: Forward to `prod-mcp-tg`
5. Security policy: `ELBSecurityPolicy-TLS13-1-2-2021-06` (TLS 1.3, modern clients)
6. Add listener

### Step 5.3: Update HTTP Listener to Redirect to HTTPS (do AFTER Step 5.2)
1. **EC2** → **Load Balancers** → `prod-mcp-alb` → **Listeners** → edit the HTTP :80 listener
2. Change default action from **Forward** → **Redirect**:
   - Redirect to: HTTPS
   - Port: 443
   - Status code: HTTP_301
3. Save
   - ⚠️ Do this ONLY after the HTTPS listener (Step 5.2) exists — redirecting before HTTPS is set up breaks the service
   - ℹ️ After this: port 80 returns 301. All real traffic flows through HTTPS (port 443) only.

---

## PHASE 6: ECS CLUSTER & SERVICE

### Step 6.1: Create ECS Cluster
1. Navigate to **ECS** → **Clusters** → **Create cluster**
2. Cluster name: `prod-mcp-cluster` *(CloudFormation names it `${EnvironmentName}-mcp-cluster`)*
3. Infrastructure: **AWS Fargate** (serverless)
4. Default capacity provider: FARGATE
5. Monitoring: **Enable Container Insights** ← required for CloudWatch metrics on tasks
6. Create cluster

### Step 6.2: Create CloudWatch Log Group (if not done earlier)
1. **CloudWatch** → **Log Groups** → **Create log group**
2. Name: `/ecs/prod-arithmetic-mcp` *(CloudFormation names it `/ecs/${EnvironmentName}-arithmetic-mcp`)*
3. Retention: 30 days

### Step 6.3: Create ECS Task Definition
1. Navigate to **ECS** → **Task Definitions** → **Create new task definition**
2. Task Definition Family: `prod-arithmetic-mcp` *(CloudFormation names it `${EnvironmentName}-arithmetic-mcp`)*
3. Launch type: **Fargate**
4. Operating system: Linux
5. CPU: **0.25 vCPU** (256 units)
6. Memory: **0.5 GB** (512 MB)
7. Network mode: **awsvpc** (required for Fargate)
8. Task role: `prod-mcp-task-role` *(created in Step 1.2.B)*
9. Task execution role: `prod-mcp-task-exec-role` *(created in Step 1.2.A)*

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
1. Navigate to **ECS** → **Clusters** → `prod-mcp-cluster`
2. Create service:
   - Launch type: Fargate
   - Service name: `prod-arithmetic-mcp-svc` *(CloudFormation names it `${EnvironmentName}-arithmetic-mcp-svc`)*
   - Desired number of tasks: 2 (for HA across 2 AZs)
   - Task definition: `prod-arithmetic-mcp` (latest revision)
3. Networking:
   - VPC: `vpc-arithmetic-mcp-prod`
   - Subnets: `private-subnet-1` and `private-subnet-2`
   - Security groups: `sg-ecs-arithmetic-mcp`
   - Public IP: DISABLED (tasks in private subnets)
4. Load balancing:
   - Load balancer type: Application Load Balancer
   - Load balancer: `prod-mcp-alb` ← select the **existing** ALB (created in Phase 5)
   - **Listener**: Select the **existing** HTTPS listener (443) — do NOT create a new listener
   - Container to load balance: `arithmetic-mcp` | Port: `8000`
   - **Target group**: Select the **existing** `prod-mcp-tg` — do NOT create a new target group
   - ℹ️ ECS will automatically register/deregister task IPs in this target group as tasks start/stop
5. Auto Scaling (optional but recommended):
   - Enable service autoscaling
   - Min capacity: 2
   - Max capacity: 4
   - Scaling policy: Target tracking
   - Target metric: CPU utilization
   - Target value: 70%
6. Create service

### Step 6.6: Verify Service is Running
1. **ECS** → **Clusters** → `prod-mcp-cluster` → **Services** → `prod-arithmetic-mcp-svc`
2. Check:
   - **Tasks** tab: Should show 2 running tasks (green)
   - **Events** tab: Should show "service reached a steady state"
   - **Logs**: CloudWatch → Log Groups → `/ecs/prod-arithmetic-mcp`
3. Wait 2-3 minutes for tasks to stabilize
4. Verify target group health: **EC2** → **Target Groups** → `prod-mcp-tg` → **Targets** → both should show `healthy`

---

## PHASE 7: AUTO SCALING CONFIGURATION

### Step 7.1: Create Target Tracking Scaling Policy
1. **ECS** → **Clusters** → `prod-mcp-cluster` → **Services** → `prod-arithmetic-mcp-svc`
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

## PHASE 7B: UPDATING THE SERVICE (Re-deployment)

Every time you change code or the Dockerfile, push a new image and trigger a rolling replace:

```powershell
# 1. Build new image
docker build -t arithmetic-mcp:v1.0.x .

# 2. Authenticate to ECR
aws ecr get-login-password --region us-east-1 | `
  docker login --username AWS --password-stdin ACCOUNT_ID.dkr.ecr.us-east-1.amazonaws.com

# 3. Tag and push
docker tag arithmetic-mcp:v1.0.x ACCOUNT_ID.dkr.ecr.us-east-1.amazonaws.com/arithmetic-mcp:v1.0.x
docker tag arithmetic-mcp:v1.0.x ACCOUNT_ID.dkr.ecr.us-east-1.amazonaws.com/arithmetic-mcp:latest
docker push ACCOUNT_ID.dkr.ecr.us-east-1.amazonaws.com/arithmetic-mcp:v1.0.x
docker push ACCOUNT_ID.dkr.ecr.us-east-1.amazonaws.com/arithmetic-mcp:latest

# 4. Force rolling replace (new tasks pull new image; old tasks stop after connection drain)
aws ecs update-service `
  --cluster prod-mcp-cluster `
  --service prod-arithmetic-mcp-svc `
  --force-new-deployment `
  --region us-east-1
```

> **Why `--force-new-deployment`?** ECS does NOT detect that `:latest` tag changed. Without this,
> running tasks keep the old image. This triggers a zero-downtime rolling replace:
> ECS starts new tasks (new image) → waits for health checks → stops old tasks.

---

## PHASE 8: TESTING & VALIDATION

### Step 8.1: Get ALB Endpoint
1. **EC2** → **Load Balancers** → `prod-mcp-alb`
2. Copy DNS name (e.g. `prod-mcp-alb-822248219.us-east-1.elb.amazonaws.com`)

### Step 8.2: Test the Service

> **Windows PowerShell**: Use `curl.exe` — NOT `curl` (alias for `Invoke-WebRequest`, hangs on SSE).
> Do NOT use port `:8000` in URLs — 8000 is the internal container port; ALB exposes 80 and 443 only.
> **Port 80 behaviour**: Before Step 5.3, HTTP forwards directly to ECS (`curl.exe http://...` works).
>   After Step 5.3 (redirect configured): port 80 returns 301 → use `curl.exe -L` or switch to HTTPS.
> **MCP is stateful**: Always call `initialize` first → extract `mcp-session-id` → include in tool calls.
> **SSE stream**: `/mcp` returns `text/event-stream` — always use `--max-time 5` or curl will hang.

```powershell
# --- Health Check ---
curl.exe http://prod-mcp-alb-822248219.us-east-1.elb.amazonaws.com/healthcheck
# Expected: {"status":"ok","service":"arithmetic-mcp"}

# After HTTPS is configured: follow redirect or use HTTPS directly
curl.exe -L http://prod-mcp-alb-822248219.us-east-1.elb.amazonaws.com/healthcheck
curl.exe https://mcp.yourdomain.com/healthcheck

# --- MCP Step 1: Initialize session (saves response headers to extract session ID) ---
curl.exe -s -D C:\temp_hdr.txt `
  -X POST http://prod-mcp-alb-822248219.us-east-1.elb.amazonaws.com/mcp `
  -H "Content-Type: application/json" `
  -H "Accept: application/json, text/event-stream" `
  -d '{\"jsonrpc\":\"2.0\",\"id\":0,\"method\":\"initialize\",\"params\":{\"protocolVersion\":\"2024-11-05\",\"capabilities\":{},\"clientInfo\":{\"name\":\"test\",\"version\":\"1.0\"}}}'

# Extract the session ID from saved headers
Get-Content C:\temp_hdr.txt | Select-String "mcp-session"
# Expected: mcp-session-id: <uuid>

# --- MCP Step 2: Call a tool (replace SESSION_ID with value above) ---
# --max-time 5 required: /mcp returns text/event-stream which keeps connection open
curl.exe --max-time 5 `
  -X POST http://prod-mcp-alb-822248219.us-east-1.elb.amazonaws.com/mcp `
  -H "Content-Type: application/json" `
  -H "Accept: application/json, text/event-stream" `
  -H "mcp-session-id: SESSION_ID" `
  -d '{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"tools/call\",\"params\":{\"name\":\"add\",\"arguments\":{\"a\":10,\"b\":5}}}'
# Expected result: 15.0
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
```powershell
# HTTP forwards (or redirects after Step 5.3) — use -L to follow redirect
curl.exe -L http://mcp.yourdomain.com/healthcheck
# or test HTTPS directly (after ACM cert + Step 5.2/5.3)
curl.exe https://mcp.yourdomain.com/healthcheck
```

---

## PHASE 10: MONITORING & MAINTENANCE

### Step 10.1: Create CloudWatch Dashboards
1. **CloudWatch** → **Dashboards** → **Create dashboard**
2. Name: `prod-arithmetic-mcp-dashboard`
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

| Symptom | Cause | Fix |
|---|---|---|
| `503 Service Unavailable` from ALB | No healthy targets in target group | EC2 → Target Groups → prod-mcp-tg → Targets — check health status |
| Targets show `unhealthy` | `/healthcheck` not returning 200 | Check task logs: CloudWatch → `/ecs/prod-arithmetic-mcp` |
| Tasks not starting / keep stopping | App crash, bad image URI, missing env var | ECS → Clusters → prod-mcp-cluster → Tasks → stopped task → Stopped reason |
| `Failed to initialize cache at /nonexistent/.cache/uv` | Debian system user has no home dir | Add `UV_NO_CACHE=1` env var in task definition |
| Tasks cannot pull ECR image | Missing execution role policy or broken NAT GW | Verify `AmazonECSTaskExecutionRolePolicy` on exec role; verify NAT GW in public subnet with Elastic IP |
| ALB returns `404` on `/mcp` | Target type `instance` instead of `ip` | Fargate requires target type `ip` — recreate target group with correct type |
| `curl` hangs on `/mcp` endpoint | `/mcp` returns `text/event-stream`; PowerShell alias waits forever | Use `curl.exe --max-time 5` |
| `Session not found` on tool call | Missing `mcp-session-id` header, or session expired | Re-run `initialize`; include `mcp-session-id` header in all tool calls |
| Cannot push to ECR | Tag immutability enabled, or Docker auth expired | Disable immutability in ECR repo settings; re-run `aws ecr get-login-password` |
| Port 80 returns `301 Moved Permanently` | HTTP listener set to redirect (Step 5.3 done) | Expected — use HTTPS (443) or follow with `curl.exe -L` |
| ALB SG outbound rule save fails | Cannot mix CIDR + SG-reference rules in same direction | Delete default `0.0.0.0/0` outbound rule first, then add SG-reference rule |
| Old code still running after image push | ECS doesn't detect `:latest` tag change | Run `aws ecs update-service --cluster prod-mcp-cluster --service prod-arithmetic-mcp-svc --force-new-deployment` |
| High latency / request timeouts | Task CPU or memory too small | Increase CPU (256→512) or Memory (512→1024) in task definition; update service to latest revision |
| ECS service pinned to old task def revision | Service not updated to new revision | ECS → Service → Update → select latest task definition revision |

---

## COST ESTIMATION

**Monthly cost (approximate):**
- ECS Fargate: 2 tasks × 0.25 vCPU × $0.04/hour × 730 hours = ~$15
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
