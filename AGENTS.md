# AGENTS.md — AI Agent Development Guide

This document defines the rules, conventions, and constraints for AI agents (Claude, Copilot, etc.)
working on the **Advanced Scaling Engineering Curriculum** repository.

---

## Repository Overview

This repository is an educational curriculum teaching progressive web application scaling techniques
on AWS. Each numbered step (`step00` through `step14`) represents a distinct architectural milestone.
Steps build on each other — breaking a prior step breaks every subsequent step.

The application stack is:
- **Backend**: Go (Echo framework) — see `shared/echo-api/`
- **Database**: MySQL 8 on RDS (t3.micro)
- **Cache**: Redis on EC2 (t3.micro)
- **Load Balancer**: AWS ALB
- **IaC**: Terraform — see `infra/terraform/modules/`
- **Load Testing**: k6

---

## Absolute Rules (Never Violate)

### Security
- **NEVER commit AWS credentials, access keys, secret keys, or tokens** to any file.
- **NEVER commit `.env` files**, `.tfvars` files containing real values, or `terraform.tfstate` files.
- **NEVER hardcode IP addresses, account IDs, or ARNs** that belong to real AWS environments.
- **NEVER** include private SSH keys, PEM files, or certificates in commits.
- All sensitive values must use placeholder patterns such as `YOUR_AWS_ACCESS_KEY`, `<YOUR_ACCOUNT_ID>`,
  or `${var.secret}`.
- SSH security groups must restrict port 22 to the learner's own IP — **never `0.0.0.0/0`**.
- RDS instances must have `publicly_accessible = false`.

### Step Integrity
- **NEVER modify an existing step's core logic** without explicit instruction and a clear migration path.
- **NEVER break backward compatibility** between steps without updating all downstream steps.
- **NEVER delete a step directory** without first confirming it is not referenced by any other step's
  README, Terraform, or application code.
- Each step must remain independently deployable from its own directory.
- Steps must not depend on side effects from previous steps' Terraform state.

### Cost Awareness
- **NEVER introduce NAT Gateways** into any Terraform configuration unless explicitly required and
  documented with a cost warning. NAT Gateways cost ~$32/month and will surprise learners.
- **NEVER use instance types larger than `t3.small`** in example configurations unless the step
  explicitly requires it and documents the cost implication.
- **NEVER create Multi-AZ RDS instances** in learning steps — single-AZ only, with a comment noting
  the production trade-off.
- Any new AWS resource addition must include an estimated monthly cost in the step's README.
- The entire curriculum (all steps, run sequentially and torn down) should cost under **$5 USD**.

### Testing
- **NEVER commit code that fails the step's own test suite** (k6 load tests, curl smoke tests,
  or Go unit tests).
- **NEVER skip health check endpoints** — every application server step must expose `/health`
  returning `{"status":"ok"}` with HTTP 200.

---

## Step Structure Requirements

Every step directory must follow this layout:

```
stepXX_<short_name>/
├── README.md                       # Japanese-language walkthrough
├── terraform/
│   ├── main.tf
│   ├── variables.tf
│   ├── outputs.tf
│   └── terraform.tfvars.example    # NEVER terraform.tfvars with real values
├── app/                            # Application source (Go, PHP/Laravel, etc.)
│   └── ...
├── scripts/
│   ├── setup.sh                    # Idempotent setup script
│   └── verify.sh                   # Smoke test / verification script
└── k6/
    └── load_test.js                # k6 load test for this step
```

### README.md Required Sections
Every step README must contain these sections in order:

1. **目的 (Purpose)** — What scaling problem this step solves.
2. **アーキテクチャ (Architecture)** — ASCII diagram of the architecture at this step.
3. **前提条件 (Prerequisites)** — What must be in place before starting.
4. **手順 (Steps)** — Numbered, command-by-command walkthrough.
5. **確認方法 (Verification)** — How to confirm the step works.
6. **コスト概算 (Cost Estimate)** — Estimated hourly and monthly cost of new resources.
7. **クリーンアップ (Cleanup)** — How to destroy all resources created in this step.
8. **次のステップ (Next Step)** — Link or reference to the next step.

### Script Requirements
- `setup.sh` must be **idempotent** — running it twice must not cause errors or duplicate resources.
- `verify.sh` must exit with code `0` on success and non-zero on failure.
- Scripts must use `set -euo pipefail` at the top.
- Scripts must print human-readable status messages for each major action.

---

## Branch Requirements

| Branch Pattern          | Purpose                                               |
|-------------------------|-------------------------------------------------------|
| `main`                  | Stable, reviewed, working state for all steps         |
| `step/XX-<name>`        | Development branch for a specific step                |
| `fix/XX-<description>`  | Bug fix for an existing step                          |
| `docs/<description>`    | Documentation-only changes                           |
| `experiment/<description>` | Experimental work — never merged without review  |

Rules:
- **No direct commits to `main`** — all changes via pull request.
- Branch names must be lowercase, hyphen-separated.
- PR title format: `[stepXX] Short description of change`.
- Every PR must reference the step number it affects.
- PRs must include the result of `verify.sh` in the PR description.

---

## Terraform Conventions

- Always run `terraform fmt` before committing `.tf` files.
- Always run `terraform validate` before committing.
- Resource naming convention: `${var.project_name}-${var.env}-<type>-<purpose>`
  - Example: `myapp-dev-sg-web`, `myapp-dev-rds-main`, `myapp-dev-ec2-app`
- All resources must have a `Name` tag and a `Step` tag.
- Use `locals {}` blocks for repeated values — never duplicate literal strings.
- Output blocks must expose all connection endpoints needed by the step's README.
- Never use `count` and `for_each` on the same resource.

```hcl
# Required tags on every resource
tags = {
  Project   = var.project_name
  Env       = var.env
  Step      = "stepXX"
  ManagedBy = "terraform"
}
```

### Terraform State
- Never commit `terraform.tfstate` or `terraform.tfstate.backup`.
- For learning steps, local state is acceptable (no S3 backend required).
- Always run `terraform destroy` before moving to the next step.

---

## Application Code Conventions

### Go Applications
- All HTTP handlers must include a `/health` endpoint returning `{"status":"ok"}`.
- Use structured logging (`log/slog` or `zerolog`) — never `fmt.Println` in production paths.
- Database connection pools must be configured with explicit `SetMaxOpenConns`,
  `SetMaxIdleConns`, and `SetConnMaxLifetime`.
- Graceful shutdown must be implemented (listen for `SIGTERM`/`SIGINT`).
- Environment variables must have documented defaults in code (see `getEnv()` pattern in
  `shared/echo-api/main.go`).

### PHP/Laravel Applications
- `.env` must never be committed — use `.env.example` only.
- Always run `php artisan config:cache` in deployment scripts.
- Database migrations must use the `--force` flag in non-interactive environments.

---

## k6 Load Test Conventions

Every `k6/load_test.js` file must:

1. Include a comment header documenting: purpose, VU count, duration, expected outcome.
2. Define a `thresholds` block with meaningful SLOs:
   ```js
   export const options = {
     thresholds: {
       http_req_duration: ['p(95)<500'],
       http_req_failed:   ['rate<0.01'],
     },
   };
   ```
3. Parameterize the target URL via `__ENV.TARGET_URL`.
4. Test the `/health` endpoint as a baseline check before the main scenario.

---

## Cost and Security Notes from Curriculum Spec

### Cost Constraints (see also `docs/cost-warning.md`)
- The entire curriculum completed and torn down should cost under **$5 USD** if run carefully.
- Steps involving RDS must prominently warn learners to **delete RDS instances immediately**
  after the step — an RDS t3.micro left running overnight costs $1–2.
- All EC2 and RDS defaults must be `t3.micro`.
- No single step should require resources that cost more than **$0.50/hour** in aggregate.
- **Never introduce NAT Gateways** — they cost ~$0.045/hour + data transfer, which adds up fast.

### Security Constraints
- EC2 SSH security groups must restrict port 22 to `var.ssh_cidr` (learner's own IP).
- RDS instances: `publicly_accessible = false`, placed in private subnet or the same VPC.
- Application secrets (DB passwords, Redis tokens) must come from environment variables or
  AWS SSM Parameter Store — never hardcoded in source or Terraform variable defaults.
- Every step README must include a security reminder callout block.

### Compliance Notes
- This is an **educational repository** — AWS resources are created and destroyed within a
  single learning session.
- Learners are responsible for their own AWS costs. The curriculum provides estimates only.
- No real user data is ever stored in the sample applications.

---

## How to Add a New Step

1. Create a branch: `git checkout -b step/XX-short-name`
2. Copy the step template: `cp -r _template/ stepXX_short_name/`
3. Fill in all required files (see Step Structure above).
4. Confirm `verify.sh` exits with code `0`.
5. Update `docs/architecture-overview.md` to include the new step.
6. Update the root `README.md` curriculum table.
7. Open a PR with title `[stepXX] Add step XX: short description`.

---

## What Agents Must NOT Do Without Explicit Instruction

- Do not refactor working application code for style alone.
- Do not upgrade dependency versions unless fixing a security vulnerability.
- Do not add new AWS services (SQS, SNS, EKS, Lambda, etc.) not already in the curriculum plan.
- Do not change the step numbering scheme.
- Do not translate Japanese README files entirely to English — bilingual is acceptable,
  full English replacement is not.
- Do not add `.github/workflows` CI/CD pipelines that trigger AWS deployments automatically
  (they would incur costs on every push).
- Do not add NAT Gateways, Multi-AZ RDS, or larger instance types without explicit instruction.
- Do not commit any file matching: `*.pem`, `*.tfstate`, `*.tfvars`, `.env`, `id_rsa*`.
