# AWS ECS Deployment — Quick Reference
## Arithmetic MCP Server

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


## 1. ARCHITECTURE OVERVIEW

### Traffic Flow Diagram

```
┌─────────────────────────────────────────────────────────────────────┐
│                        INTERNET (0.0.0.0/0)                        │
└───────────────────────────────┬─────────────────────────────────────┘
                                │  port 80  → forward (→ 301 redirect after Step 5.3)
                                │  port 443 → forward to Target Group
                    ┌───────────▼───────────┐
                    │  ALB: prod-mcp-alb    │   ← PUBLIC SUBNETS
                    │  (internet-facing)    │     us-east-1a + us-east-1b
                    │  SG: alb-sg           │
                    └───────────┬───────────┘
                                │
                    ┌───────────▼───────────┐
                    │  Target Group:        │
                    │  prod-mcp-tg          │
                    │  health: /healthcheck │
                    │  port 8000, type: ip  │
                    └───────────┬───────────┘
                                │ routes to registered task IPs
┌───────────────────────────────▼─────────────────────────────────────┐
│  ECS Cluster: prod-mcp-cluster                                      │
│  ┌───────────────────────────────────────────────────────────────┐  │
│  │  ECS Service: prod-arithmetic-mcp-svc                         │  │
│  │  Task Definition: prod-arithmetic-mcp  |  Desired: 2          │  │
│  │  Min: 2  |  Max: 4  |  Rolling deploys  |  awsvpc network     │  │
│  │                                                               │  │
│  │  ┌──────────────────────────┐  ┌──────────────────────────┐   │  │
│  │  │  Task 1 (Fargate)        │  │  Task 2 (Fargate)        │   │  │
│  │  │  Private Subnet A        │  │  Private Subnet B        │   │  │
│  │  │  10.0.10.x  us-east-1a   │  │  10.0.20.x  us-east-1b   │   │  │
│  │  │  NO public IP            │  │  NO public IP            │   │  │
│  │  │  ┌────────────────────┐  │  │  ┌────────────────────┐  │   │  │
│  │  │  │  Container:        │  │  │  │  Container:        │  │   │  │
│  │  │  │  arithmetic-mcp    │  │  │  │  arithmetic-mcp    │  │   │  │
│  │  │  │  port: 8000        │  │  │  │  port: 8000        │  │   │  │
│  │  │  └────────────────────┘  │  │  └────────────────────┘  │   │  │
│  │  └──────────────────────────┘  └──────────────────────────┘   │  │
│  └───────────────────────────────────────────────────────────────┘  │
└──────────────────────────────┬──────────────────────────────────────┘
                               │ outbound only (no public IP on tasks)
                    ┌──────────▼──────────┐
                    │   NAT Gateway       │   ← PUBLIC SUBNET (Elastic IP)
                    └──────────┬──────────┘
                               │
              ┌────────────────┴─────────────────┐
              │                                  │
  ┌───────────▼───────────┐       ┌──────────────▼────────────┐
  │  ECR: arithmetic-mcp  │       │  CloudWatch Logs           │
  │  (Docker images)      │       │  /ecs/prod-arithmetic-mcp  │
  └───────────────────────┘       └────────────────────────────┘

VPC: vpc-arithmetic-mcp-prod  (10.0.0.0/16)
├── Public  Subnet A: 10.0.1.0/24  (us-east-1a) → ALB + NAT Gateway
├── Public  Subnet B: 10.0.2.0/24  (us-east-1b) → ALB
├── Private Subnet A: 10.0.10.0/24 (us-east-1a) → ECS Tasks
└── Private Subnet B: 10.0.20.0/24 (us-east-1b) → ECS Tasks
```

### Component Hierarchy
```
ECS Cluster: prod-mcp-cluster  (Fargate — no EC2 servers to manage)
  └── ECS Service: prod-arithmetic-mcp-svc
        │  Desired: 2 tasks | Min: 2 | Max: 4 | Rolling deploys
        │  Auto-registers task IPs into Target Group on start; deregisters on stop
        │  Task Definition: prod-arithmetic-mcp  (versioned, immutable blueprint)
        │
        ├── Task 1 (Fargate container instance)   [Private Subnet A: 10.0.10.x, us-east-1a]
        │   └── Container: arithmetic-mcp
        │       Image : <ACCOUNT>.dkr.ecr.us-east-1.amazonaws.com/arithmetic-mcp:tag
        │       Port  : 8000  |  CPU: 0.25 vCPU  |  Mem: 512 MB
        │       Env   : MCP_TRANSPORT=streamable-http, HOST=0.0.0.0, PORT=8000
        │               UV_NO_CACHE=1, PYTHONUNBUFFERED=1
        │       Logs  : awslogs → /ecs/prod-arithmetic-mcp
        │
        └── Task 2 (Fargate container instance)   [Private Subnet B: 10.0.20.x, us-east-1b]
            └── Container: arithmetic-mcp
                Image : <ACCOUNT>.dkr.ecr.us-east-1.amazonaws.com/arithmetic-mcp:tag
                Port  : 8000  |  CPU: 0.25 vCPU  |  Mem: 512 MB
                Env   : MCP_TRANSPORT=streamable-http, HOST=0.0.0.0, PORT=8000
                        UV_NO_CACHE=1, PYTHONUNBUFFERED=1
                Logs  : awslogs → /ecs/prod-arithmetic-mcp
```

---

## 2. WHY EACH COMPONENT EXISTS

### Why ECS Fargate (not EC2, Lambda, App Runner)?

| Option | Problem |
|---|---|
| **EC2** | Must patch OS, manage Docker daemon, handle scaling yourself — too much ops overhead |
| **Lambda** | 15-min timeout; cold starts hurt latency; MCP uses SSE (long-lived connections) which Lambda cannot hold open |
| **App Runner** | Less VPC control; no private subnet support without extra setup; limited configuration |
| **ECS Fargate ✅** | Serverless containers — no server management, native VPC/private-subnet support, integrates directly with ALB + ECR, pay per task-second |

### Why ALB (not NLB or API Gateway)?

- **ALB** is Layer 7 (HTTP/HTTPS-aware) — can route by path, inspect headers, terminate TLS
- MCP uses HTTP + SSE (`text/event-stream`) — ALB supports streaming responses natively
- ALB integrates natively with ECS Service for automatic target registration/deregistration
- NLB is Layer 4 (TCP only) — no HTTP health checks; API Gateway has a 29-second timeout (incompatible with SSE)

### Why VPC with PUBLIC + PRIVATE Subnets?

```
PUBLIC subnet  (has route to Internet Gateway)
  ├── ALB        — must be internet-facing to accept external traffic ✅
  └── NAT GW     — needs a public Elastic IP to route outbound traffic ✅

PRIVATE subnet  (has route to NAT Gateway only — no direct internet path)
  └── ECS Tasks  — NOT directly reachable from internet ✅
                   can still pull images from ECR and send logs to CloudWatch
                   via NAT Gateway (outbound only)
```

**Security principle:** Application containers should NEVER have public IPs. If a container is compromised, the attacker cannot reach it directly from the internet — they must go through the ALB first. This is defence-in-depth.

**Why two AZs?** If `us-east-1a` has an outage, tasks in `us-east-1b` keep serving traffic. The ALB automatically stops routing to the failed AZ. Single-AZ = single point of failure.

### Why NAT Gateway?

ECS tasks in private subnets have no internet route by default. They need outbound access to:

- Pull Docker images from ECR (image layers come from S3 over the internet)
- Send structured logs to CloudWatch Logs
- Reach any external APIs your application calls

NAT Gateway sits in the public subnet with a fixed Elastic IP. It translates private IPs → its own public IP for outbound traffic only — ALL inbound connections are blocked, so tasks remain unreachable from the internet.

---

## 3. HOW COMPONENTS CONNECT

### ECS Cluster → Service → Task → ALB

```
ECS Cluster: prod-mcp-cluster
  │
  │  (logical grouping — a container for your services; maps to Fargate compute pool)
  │
  └── ECS Service: prod-arithmetic-mcp-svc
        │
        │  (maintains desired task count; manages rolling deploys; owns ALB registration)
        │
        ├── Task 1 (Fargate) [Private Subnet A: 10.0.10.x, us-east-1a]  ──► registers IP:8000 → Target Group
        │   └── Container: arithmetic-mcp  (port 8000 | 0.25 vCPU | 512 MB)
        ├── Task 2 (Fargate) [Private Subnet B: 10.0.20.x, us-east-1b]  ──► registers IP:8000 → Target Group
        │   └── Container: arithmetic-mcp  (port 8000 | 0.25 vCPU | 512 MB)
        │
        └── Task Definition: prod-arithmetic-mcp   (immutable versioned blueprint)
              ├── Docker image: <ACCOUNT>.dkr.ecr.us-east-1.amazonaws.com/arithmetic-mcp:tag
              ├── CPU: 256 (.25 vCPU), Memory: 512 MB
              ├── Port mapping: container 8000 → host 8000
              ├── Env vars: MCP_TRANSPORT=streamable-http, HOST=0.0.0.0, PORT=8000, UV_NO_CACHE=1
              ├── Log driver: awslogs → /ecs/prod-arithmetic-mcp (retention: 30 days)
              ├── Task Execution Role: prod-mcp-task-exec-role
              └── Task Role: prod-mcp-task-role
```

**How ALB connection works (automatic):**

1. You create the ECS Service and point it at ALB `prod-mcp-alb`, listener `443`, target group `prod-mcp-tg`
2. When a task starts → ECS calls `RegisterTargets` (adds task private IP + port 8000 to `prod-mcp-tg`)
3. ALB waits for target to pass health check (`GET /healthcheck` → HTTP 200)
4. ALB begins routing real traffic to that task
5. When a task stops (deploy, crash, scale-in) → ECS calls `DeregisterTargets` → ALB drains connections and stops routing
6. You never manually touch the target group — ECS manages it entirely on every deploy

### Security Group Chain (defence-in-depth)

```
Internet
  │ TCP 80, 443 from 0.0.0.0/0
  ▼
ALB Security Group
  │ Inbound:  0.0.0.0/0 → port 80, 443
  │ Outbound: ECS SG    → port 8000 only  ← locked to ECS SG reference
  ▼
ECS Security Group
  │ Inbound:  ALB SG → port 8000 only  ← only traffic from ALB, not open internet
  │ Outbound: 0.0.0.0/0 → all ports    ← for ECR pull, CloudWatch, etc.
  ▼
ECS Tasks (internal port 8000)
```

Port 8000 is the **internal** container port — never exposed to the internet. Internet users only see ports 80/443.

> **AWS rule:** You cannot mix CIDR-based and SG-reference rules in the same outbound direction. Delete the default `0.0.0.0/0` outbound rule on the ALB SG before adding the ECS SG-reference outbound rule.

### Two IAM Roles Explained

| Role | Who uses it | What it authorizes |
|---|---|---|
| **Task Execution Role** (`prod-mcp-task-exec-role`) | ECS control plane (AWS itself) | Pull Docker image from ECR; write log events to CloudWatch — runs BEFORE your app starts |
| **Task Role** (`prod-mcp-task-role`) | Your running application code | AWS API calls the app makes at runtime (e.g., S3, Secrets Manager, DynamoDB) |

The execution role is always required. The task role can have zero policies if your app doesn't call AWS APIs.

### Task Definition vs Running Container — What's the Difference?

This is the most common source of confusion. There are TWO places you see a "container":

```
Task Definition: prod-arithmetic-mcp   ← BLUEPRINT (stored in AWS, never runs itself)
│
│  Defines: image URI, CPU, memory, port, env vars, IAM roles, log config
│  Each edit creates a new immutable REVISION  (:1, :2, :3 ...)
│  Think of it like a docker-compose.yml or a class definition in code
│
│  When ECS Service starts a Task based on this definition:
│    1. ECS reads the Task Definition
│    2. Pulls the Docker image from ECR
│    3. Creates and starts a Container with those exact settings
│
├── Running Task 1  (INSTANCE of the definition)
│     └── Container: arithmetic-mcp   ← LIVE Docker process, private IP: 10.0.10.x
│
└── Running Task 2  (another INSTANCE — identical copy)
      └── Container: arithmetic-mcp   ← LIVE Docker process, private IP: 10.0.20.x
```

**In short:** Task Definition = recipe. Running Task = the dish made from that recipe.
Task 1 and Task 2 both use the **same** Task Definition — same image, same config, different private IPs.
You update the Task Definition (new revision) to deploy a new version of the application.


Task Definition container/	Running container inside a Task
What it is -	Blueprint / specification	Live Docker process
Stored where -	In AWS (prod-arithmetic-mcp:revision) /	In memory on Fargate compute
Runs?	Never — it's a definition /	Yes — it's the actual app
How many?	One definition, multiple revisions /	One per running Task


### Target Group — Why Does the Same Name Appear in Both ALB and ECS?

`prod-mcp-tg` is the **meeting point** between the ALB and ECS. It is configured once and referenced in both:

```
ALB Listener (port 443)
  │  Rule: "forward all requests → prod-mcp-tg"
  │  ALB sends HTTP requests to whichever IPs are healthy in this group
  ▼
Target Group: prod-mcp-tg       ← THE BRIDGE
  │  Holds a dynamic list of {IP : port} entries
  │  Runs health checks: GET /healthcheck on each IP:8000 every 30 s
  │  Marks each entry healthy or unhealthy
  │  ALB only routes to healthy entries
  ▲
ECS Service: prod-arithmetic-mcp-svc
  │  Config: "register my tasks into → prod-mcp-tg"
  │  Task 1 starts at 10.0.10.45:8000  → ECS calls RegisterTargets   → added to group
  │  Task 2 starts at 10.0.20.87:8000  → ECS calls RegisterTargets   → added to group
  │  Task stops / deploy / crash        → ECS calls DeregisterTargets → removed from group
```

ALB says: "forward requests to whatever healthy IPs are registered in prod-mcp-tg"

ECS says: "when a task starts, register its IP:8000 into prod-mcp-tg; when it stops, remove it"

The Target Group sits in the middle, runs health checks on every registered IP, and only tells the ALB about healthy ones

**Why the same group?** Because ALB needs to know *where* to send traffic, and ECS needs a place to *register* its dynamically assigned task IPs. The Target Group is the shared registry that connects them. You create it once (in Phase 5, ALB setup) and point both the ALB listener and the ECS Service at it.

---

## 4. RESOURCE NAMES (CloudFormation — EnvironmentName=prod)

| Resource | Actual Name | CloudFormation Pattern |
|---|---|---|
| ALB | `prod-mcp-alb` | `${EnvironmentName}-mcp-alb` |
| Target Group | `prod-mcp-tg` | `${EnvironmentName}-mcp-tg` |
| ECS Cluster | `prod-mcp-cluster` | `${EnvironmentName}-mcp-cluster` |
| ECS Service | `prod-arithmetic-mcp-svc` | `${EnvironmentName}-arithmetic-mcp-svc` |
| Task Definition | `prod-arithmetic-mcp` | `${EnvironmentName}-arithmetic-mcp` |
| Task Exec Role | `prod-mcp-task-exec-role` | `${EnvironmentName}-mcp-task-exec-role` |
| Task Role | `prod-mcp-task-role` | `${EnvironmentName}-mcp-task-role` |
| Log Group | `/ecs/prod-arithmetic-mcp` | `/ecs/${EnvironmentName}-arithmetic-mcp` |
| ECR Repo | `arithmetic-mcp` | (manual) |
| VPC | `vpc-arithmetic-mcp-prod` | (manual) |

---

## 5. KEY IDENTIFIERS (fill in after deployment)

```
ACCOUNT_ID : <your-aws-account-id>
REGION     : us-east-1
ALB DNS    : prod-mcp-alb-822248219.us-east-1.elb.amazonaws.com

VPC
  VPC ID            : vpc-
  Public  Subnet 1  : subnet-   (us-east-1a)
  Public  Subnet 2  : subnet-   (us-east-1b)
  Private Subnet 1  : subnet-   (us-east-1a)
  Private Subnet 2  : subnet-   (us-east-1b)
  Internet Gateway  : igw-
  NAT Gateway       : nat-

Security Groups
  ALB SG ID         : sg-
  ECS SG ID         : sg-

ECR
  Repository URI    : <ACCOUNT_ID>.dkr.ecr.us-east-1.amazonaws.com/arithmetic-mcp
  Latest image tag  : v1.0.x

Load Balancer
  ALB ARN           : arn:aws:elasticloadbalancing:...
  Target Group ARN  : arn:aws:elasticloadbalancing:...
  HTTPS Cert ARN    : arn:aws:acm:...

ECS
  Cluster ARN       : arn:aws:ecs:...
  Service ARN       : arn:aws:ecs:...
  Task Def ARN      : arn:aws:ecs:...:task-definition/prod-arithmetic-mcp:N

IAM
  Task Exec Role    : arn:aws:iam::<ACCOUNT_ID>:role/prod-mcp-task-exec-role
  Task Role         : arn:aws:iam::<ACCOUNT_ID>:role/prod-mcp-task-role

CloudWatch
  Log Group         : /ecs/prod-arithmetic-mcp
```

---

## 6. DEPLOYMENT PHASES SUMMARY

| Phase | What you build | Est. time |
|---|---|---|
| 1 | IAM Roles (execution + task), CloudWatch Log Group | 10 min |
| 2 | VPC, 4 subnets, IGW, NAT Gateway, Route Tables, **Security Groups** (ALB SG + ECS SG) | 25 min |
| 3 | ECR Repository, Docker build + push | 15 min |
| 4 | TLS Certificate — request ACM cert (required before HTTPS listener in Phase 5) | 5 min |
| 5 | ALB, HTTP Listener (80→**forward** to TG, updated to redirect in Step 5.3), HTTPS Listener (443→TG), Target Group | 15 min |
| 6 | ECS Cluster, Task Definition, ECS Service (links ALB + target group) | 20 min |
| 7 | Auto Scaling (optional, recommended for production) | 10 min |
| 7B | Re-deployment workflow — push new image + `--force-new-deployment` | — |
| 8 | Testing & validation (health check, MCP session, tool call) | 15 min |
| 9 | DNS / Route 53 alias record → ALB (optional) | 5 min |
| 10 | CloudWatch Alarms + Dashboard | 20 min |

**Total: ~2 hours**

> **Dependency order matters:** IAM + VPC must exist before ECS. ALB must exist before ECS Service. ECR image must exist before Task Definition references it.

---

## 7. TESTING THE DEPLOYMENT

### Step 1 — Health Check

```powershell
# Use curl.exe — NOT PowerShell's curl alias (Invoke-WebRequest)
curl.exe http://prod-mcp-alb-822248219.us-east-1.elb.amazonaws.com/healthcheck
# Expected: {"status":"ok","service":"arithmetic-mcp"}
```

### Step 2 — MCP Session Initialization

MCP is a **stateful protocol**. You must call `initialize` first to get a session ID, then include that session ID in every subsequent request.

```powershell
# Step 2a: Send initialize — save response headers to file
curl.exe -s -D C:\temp_hdr.txt `
  -X POST http://prod-mcp-alb-822248219.us-east-1.elb.amazonaws.com/mcp `
  -H "Content-Type: application/json" `
  -d '{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{\"protocolVersion\":\"2024-11-05\",\"capabilities\":{},\"clientInfo\":{\"name\":\"test\",\"version\":\"1.0\"}}}'

# Step 2b: Read session ID from saved headers
Get-Content C:\temp_hdr.txt | Select-String "mcp-session"
# Expected: mcp-session-id: <uuid>
```

### Step 3 — Call a Tool

```powershell
# Replace SESSION_ID with the value from Step 2b
curl.exe --max-time 5 `
  -X POST http://prod-mcp-alb-822248219.us-east-1.elb.amazonaws.com/mcp `
  -H "Content-Type: application/json" `
  -H "mcp-session-id: SESSION_ID" `
  -d '{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"tools/call\",\"params\":{\"name\":\"add\",\"arguments\":{\"a\":10,\"b\":5}}}'
# Expected result: 15.0
```

> **Why `--max-time 5`?** `/mcp` returns `Content-Type: text/event-stream` (SSE). Without a timeout, curl waits forever for the stream to close. `--max-time 5` collects the response then exits.

### Step 4 — View Logs

```powershell
aws logs tail /ecs/prod-arithmetic-mcp --follow --region us-east-1
# Console: CloudWatch → Log Groups → /ecs/prod-arithmetic-mcp
```

---

## 8. UPDATING THE SERVICE (re-deployment)

```powershell
# 1. Build
docker build -t arithmetic-mcp:v1.0.x .

# 2. Auth to ECR
aws ecr get-login-password --region us-east-1 | `
  docker login --username AWS --password-stdin ACCOUNT_ID.dkr.ecr.us-east-1.amazonaws.com

# 3. Tag + push
docker tag arithmetic-mcp:v1.0.x ACCOUNT_ID.dkr.ecr.us-east-1.amazonaws.com/arithmetic-mcp:v1.0.x
docker tag arithmetic-mcp:v1.0.x ACCOUNT_ID.dkr.ecr.us-east-1.amazonaws.com/arithmetic-mcp:latest
docker push ACCOUNT_ID.dkr.ecr.us-east-1.amazonaws.com/arithmetic-mcp:v1.0.x
docker push ACCOUNT_ID.dkr.ecr.us-east-1.amazonaws.com/arithmetic-mcp:latest

# 4. Force rolling replace (new tasks pull new image, old tasks stop after drain)
aws ecs update-service `
  --cluster prod-mcp-cluster `
  --service prod-arithmetic-mcp-svc `
  --force-new-deployment `
  --region us-east-1
```

> **Why `--force-new-deployment`?** ECS does NOT detect that `:latest` changed. You must explicitly trigger redeployment. ECS performs a zero-downtime rolling replace: starts new tasks → waits for health checks → stops old tasks.

---

## 9. USEFUL AWS CLI COMMANDS

```powershell
# List running tasks
aws ecs list-tasks --cluster prod-mcp-cluster --region us-east-1

# Describe service (desired / running / pending counts)
aws ecs describe-services --cluster prod-mcp-cluster --services prod-arithmetic-mcp-svc --region us-east-1

# Scale up/down
aws ecs update-service --cluster prod-mcp-cluster --service prod-arithmetic-mcp-svc --desired-count 4 --region us-east-1

# List task definition revisions
aws ecs list-task-definitions --family-prefix prod-arithmetic-mcp --region us-east-1

# Check target group health
aws elbv2 describe-target-health --target-group-arn <TG_ARN> --region us-east-1

# Describe ALB
aws elbv2 describe-load-balancers --names prod-mcp-alb --region us-east-1

# Stream logs
aws logs tail /ecs/prod-arithmetic-mcp --follow --region us-east-1
```

---

## 10. TROUBLESHOOTING QUICK REFERENCE

| Symptom | Most Likely Cause | Fix |
|---|---|---|
| `503 Service Unavailable` | No healthy targets in target group | EC2 → Target Groups → prod-mcp-tg → Targets — check health status |
| Targets show `unhealthy` | `/healthcheck` not returning 200 | Check ECS task logs in CloudWatch for crash/startup error |
| Tasks not starting / keep stopping | App crash, bad image, or missing env var | CloudWatch → `/ecs/prod-arithmetic-mcp` → stopped reason |
| `Failed to initialize cache at /nonexistent/.cache/uv` | Debian system user lacks home directory | Set `UV_NO_CACHE=1` env var in task definition |
| Tasks cannot pull ECR image | Missing execution role policy or broken NAT | Verify `AmazonECSTaskExecutionRolePolicy` on exec role; verify NAT GW in public subnet with Elastic IP |
| ALB returns `404` on `/mcp` | Target type is `instance` instead of `ip` | Fargate requires target type `ip`; recreate target group with correct type |
| `curl` hangs on `/mcp` | MCP returns `text/event-stream` — PowerShell alias waits forever | Use `curl.exe --max-time 5` (not PowerShell `Invoke-WebRequest`) |
| `Session not found` on tool call | Missing `mcp-session-id` header, or session expired | Re-run `initialize` request; include `mcp-session-id` header in tool calls |
| Cannot push to ECR | Tag immutability ON, or auth expired | Disable immutability in ECR → Repositories → Edit; re-run `get-login-password` |
| HTTP port 80 returns redirect | Correct behaviour — HTTP listener is set to 301 redirect to HTTPS | Use port 443, or follow with `curl.exe -L` |
| ALB SG outbound rule error | Cannot mix CIDR + SG-reference rules | Delete default `0.0.0.0/0` outbound rule first, then add SG-reference rule |
| Old code still running after push | ECS using cached task definition or no `--force-new-deployment` | Run `aws ecs update-service --force-new-deployment` |

---

## 11. COST BREAKDOWN (Monthly estimate, us-east-1)

| Service | Details | Est. Cost |
|---|---|---|
| ECS Fargate | 2 tasks × 0.25 vCPU × $0.04/hr × 730h | ~$15 |
| ECS Fargate | 2 tasks × 0.5 GB mem × $0.004/hr × 730h | ~$3 |
| ALB | Fixed hourly charge | ~$22 |
| ALB | LCU (request processing) | ~$2 |
| NAT Gateway | Hourly ($0.045/hr) | ~$33 |
| NAT Gateway | Data processed (~10 GB/day) | ~$14 |
| ECR | Storage (5 GB) | ~$1 |
| CloudWatch | Logs ingestion + storage | ~$5 |
| Data Transfer | Outbound to internet | ~$5 |
| **Total** | | **~$100/month** |

> **Largest cost driver is NAT Gateway** (~47%). For dev/test, consider VPC Interface Endpoints for ECR and CloudWatch to reduce NAT data costs.

---

## 12. POST-DEPLOYMENT CHECKLIST

**Immediately after deployment:**
- [ ] `curl.exe http://<ALB-DNS>/healthcheck` returns `{"status":"ok",...}`
- [ ] Both ECS tasks show `RUNNING` in console
- [ ] Both targets show `healthy` in EC2 → Target Groups → prod-mcp-tg
- [ ] CloudWatch log group `/ecs/prod-arithmetic-mcp` has log streams
- [ ] MCP `initialize` returns a `mcp-session-id` header
- [ ] At least one tool call succeeds (e.g., `add(10, 5)` → `15.0`)

**Within first week:**
- [ ] Attach ACM certificate and enable HTTPS listener (port 443)
- [ ] Set up Route 53 alias record pointing to ALB DNS
- [ ] Enable Container Insights on cluster (ECS → Cluster → Update)
- [ ] Create CloudWatch alarms: CPU > 80%, memory > 80%, unhealthy target count > 0
- [ ] Test auto-scaling by simulating load
- [ ] Verify rolling deployment works (push new image, watch zero-downtime replace)

**Before production traffic:**
- [ ] Run load test (100+ req/s sustained)
- [ ] Fill in all ARNs/IDs in Section 5 (Key Identifiers)
- [ ] Enable ECR image scanning on push
- [ ] Review IAM roles — remove any over-permissive policies
- [ ] Confirm log retention set to 30 days

---

## RELATED FILES

| File | Purpose |
|---|---|
| `AWS_DEPLOYMENT_GUIDE.md` | Full step-by-step 10-phase manual deployment guide |
| `aws/infrastructure.yaml` | CloudFormation template — all AWS resources |
| `aws/deploy.sh` | Shell script for automated deployment |
| `Dockerfile` | Container build (multi-stage; Fargate-ready) |
| `server.py` | FastMCP server with `/healthcheck` and 6 arithmetic tools |
