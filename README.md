# K8s Assistant Lab

A hands-on Kubernetes troubleshooting lab on AWS. One script deploys five full-stack applications to Amazon EKS. You then break them on purpose and fix them.

![Lab architecture](docs/images/architecture.svg)

Each app has a React frontend served by nginx and a Node.js backend, in its own namespace. They share one Application Load Balancer, one RDS PostgreSQL instance, and an ECR registry. Each app gets its own URL, `https://<app>.<your-domain>`. The full design is in [docs/architecture.md](docs/architecture.md).

Every exercise follows the same loop:

```text
symptom -> scope -> Kubernetes or AWS evidence -> root cause -> fix -> verify recovery
```

> **Cost warning:** the lab creates billable AWS resources (EKS, EC2, NAT Gateway, ALB, RDS). Run [`./scripts/teardown.sh`](#8-destroy-the-lab) when you are done.

## Contents

1. [Check the prerequisites](#1-check-the-prerequisites)
2. [Configure the lab](#2-configure-the-lab)
3. [Launch the lab](#3-launch-the-lab)
4. [Get your kubeconfig](#4-get-your-kubeconfig)
5. [Verify the deployment](#5-verify-the-deployment)
6. [Give teammates access (RBAC)](#6-give-teammates-access-rbac)
7. [Work through the incident scenarios](#7-work-through-the-incident-scenarios)
8. [Destroy the lab](#8-destroy-the-lab)

## 1. Check the prerequisites

- Bash 4.4 or newer: Linux, WSL, or macOS with Bash from Homebrew. The macOS system Bash 3.2 is too old.
- Terraform, AWS CLI, kubectl, Docker, Helm, jq, `envsubst`, `curl`, and `nslookup`.
- An AWS account with credentials configured.
- A Route 53 **public hosted zone** for your domain, with the registrar's NS records pointing at it.

Resource names are fixed, so run only one lab per AWS account.

```bash
aws sts get-caller-identity
docker info
terraform version
kubectl version --client
helm version
```

## 2. Configure the lab

The only required setting is your domain:

```bash
cp terraform/terraform.tfvars.example terraform/terraform.tfvars
```

Open `terraform/terraform.tfvars` and set `dns_zone_name` to your hosted zone, for example `dns_zone_name = "labs.example.org"`.

Everything else has a default: region `us-east-1`, cluster `dev-cluster`, 3 × `t3.medium` nodes, Kubernetes 1.33, and a `db.t3.micro` PostgreSQL 17 instance. To change a default, add that variable to `terraform.tfvars`. The full list is in [terraform/variables.tf](terraform/variables.tf).

## 3. Launch the lab

From the repository root:

```bash
./scripts/setup.sh
```

The script:

1. Checks your tools, AWS login, `terraform.tfvars`, the hosted zone, and DNS delegation.
2. Finds or requests a `*.<domain>` ACM certificate.
3. Runs `terraform apply` to create the VPC, EKS, ECR, RDS, and IAM resources.
4. Points `kubectl` at the new cluster.
5. Builds the ten images and pushes them to ECR.
6. Creates the namespaces and the access roles from [rbac/](rbac/).
7. Creates one database and user per app and stores the credentials as Kubernetes Secrets.
8. Deploys the five apps and Redis, then waits for every rollout.
9. Installs metrics-server and the AWS Load Balancer Controller, applies the Ingresses, and creates the DNS records.
10. Prints the application URLs and the path of the read-only kubeconfig, `kubeconfigs/team-readonly.kubeconfig`.

When it finishes, the cluster is running and `kubeconfigs/team-readonly.kubeconfig` is ready to use. Setup takes 20 minutes or more. You can safely run it again. If a rollout fails, the script names the failing Deployment. Fix the cause and re-run.

## 4. Get your kubeconfig

A kubeconfig is the file `kubectl` reads to find the cluster and log in. There are three ways to get one, depending on who you are.

| Who | Needs an AWS account? | How they get a kubeconfig | Access |
|---|---|---|---|
| **You** (the person who ran `setup.sh`) | Yes | `setup.sh` sets it up, or run `aws eks update-kubeconfig` | Cluster admin |
| **Other IAM users in the same AWS account** | Yes | Assume the `dev-cluster-eks-admin-role` | Cluster admin |
| **Teammates** | No | `kubeconfigs/team-readonly.kubeconfig`, written automatically by `terraform apply`, or a personal file from `./scripts/users.sh` | Read-only, plus an optional personal sandbox ([section 6](#6-give-teammates-access-rbac)) |

**As the admin**, on the machine that ran `setup.sh`, kubectl is already configured. On any other machine, run:

```bash
aws eks update-kubeconfig --name dev-cluster --region us-east-1
kubectl get nodes
```

Use your own values for `--name` and `--region` if you changed them in `terraform.tfvars`. This adds a context to `~/.kube/config` that logs in through your AWS credentials, so nothing secret is written to the file.

**Another IAM user in the same account** can become admin by assuming the role that Terraform created:

```bash
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
aws eks update-kubeconfig --name dev-cluster --region us-east-1 \
  --role-arn arn:aws:iam::${ACCOUNT_ID}:role/dev-cluster-eks-admin-role
```

Their IAM user needs permission for `sts:AssumeRole` on that role.

## 5. Verify the deployment

```bash
kubectl get nodes
kubectl get deployments -A
kubectl get pods -A
kubectl get ingress -A
```

Every Deployment should show all of its replicas Ready. The domain is saved in `.lab-domain`, so you can print the app URLs with:

```bash
for app in ecommerce banking food-delivery student-portal support-tickets; do
  echo "https://${app}.$(cat .lab-domain)"
done
```

Open each URL and confirm the app loads before you break anything. To see what a healthy app looks like:

```bash
kubectl get all -n banking
kubectl get events -n banking
kubectl logs -n banking deploy/banking-backend
kubectl top pods -A
```

## 6. Give teammates access (RBAC)

Teammates can use your cluster without an AWS account. Each one logs in with a Kubernetes ServiceAccount token. You generate that token, inside a ready-made kubeconfig file, with `scripts/users.sh`.

### How access works

`setup.sh` applies [rbac/cluster-access.yaml](rbac/cluster-access.yaml) once. Every teammate is a ServiceAccount in the `lab-users` namespace, and that whole group gets two cluster-wide bindings:

- The built-in **`view`** role, which allows reading almost everything in every namespace. It deliberately excludes Secrets, which keeps the database passwords private.
- **`lab-cluster-reader`**, which adds read access to nodes and namespaces.

A teammate with a personal file also gets a **`sandbox-<name>`** namespace. There, the `lab-sandbox-user` role lets them create pods, Deployments, Services, ConfigMaps, Jobs, and similar objects. The sandbox has a quota of about five small pods, and LoadBalancer Services, NodePorts, and storage volumes are blocked.

| Teammates CAN | Teammates CANNOT |
|---|---|
| List and describe pods, Deployments, Services, Ingresses, and HPAs in every namespace | Read any Secret outside their sandbox |
| Read logs and events, and run `kubectl top` | Create, edit, scale, or delete anything in the five apps |
| View nodes and namespaces | Run `exec` or `port-forward` into the app pods |
| Create and delete workloads in their own `sandbox-<name>` | Create Ingresses, LoadBalancers, roles, or ServiceAccounts |

A `Forbidden` error outside the sandbox means the permissions are working as intended.

### Shared read-only file

The setup generates `kubeconfigs/team-readonly.kubeconfig` automatically. It has the read-only access described above, and you can hand it to anyone who only needs to look at the cluster.

### Create a personal kubeconfig for a teammate

For a personal file with a sandbox, run these as the admin, from the repository root:

```bash
./scripts/users.sh add alex sam           # one file per person, each with a sandbox
./scripts/users.sh add class --readonly   # or one shared read-only file for a whole group
./scripts/users.sh list                   # show users and sandbox usage
./scripts/users.sh remove alex            # revoke access and delete the sandbox
```

The script shows which cluster it is about to change and asks you to confirm. Add `-y` to skip the prompt. It then:

1. Creates the ServiceAccount and a long-lived token in `lab-users`.
2. For a personal file, creates `sandbox-<name>` with its quota, limits, and RoleBinding.
3. Writes `kubeconfigs/<name>.kubeconfig`. This folder is gitignored.
4. Tests the file with `kubectl auth can-i` to confirm it has exactly the expected permissions.

Use personal files for small teams (up to about 10 people on the default three nodes). For a large class, a single `--readonly` file avoids filling the cluster with sandboxes.

### Keep the files safe

- **Each file holds a login token.** Send it privately, never through Git or a public channel. Tokens do not expire, so revoke them with `./scripts/users.sh remove <name>`.
- **Sandboxes use cluster capacity.** If pods stay `Pending`, raise `node_group_desired_size` in `terraform/terraform.tfvars` and re-run `./scripts/setup.sh`.
- **The API endpoint and the app URLs are public.** Anyone with a token can query the cluster, and anyone can call the apps' `/api/chaos/*` endpoints. Agree with your teammates on who triggers incidents.

## 7. Work through the incident scenarios

Each scenario has a guide that starts from the symptom, and a script in [scripts/chaos/](scripts/chaos/) that causes the incident. Run the script, then diagnose the problem with the guide, without reading ahead to the answer.

| Scenario | Trigger | Main skill |
|---|---|---|
| [Bad container image](docs/incident-scenarios/01-bad-container-image.md) | `./scripts/chaos/bad-deploy.sh <namespace> <deployment> <container>` | ECR and Deployments |
| [Bad ConfigMap rollout](docs/incident-scenarios/02-bad-configmap-rollout.md) | `./scripts/chaos/break-config.sh <app>` | ConfigMaps and health probes |
| [OOMKilled and resource limits](docs/incident-scenarios/03-oomkilled-resource-limits.md) | `./scripts/chaos/shrink-limits.sh <app>` | Resource management |
| [ALB and Ingress routing failure](docs/incident-scenarios/04-alb-ingress-routing.md) | `./scripts/chaos/break-ingress.sh <app>` | ALB and Kubernetes networking |
| [High application latency](docs/incident-scenarios/05-high-application-latency.md) | `./scripts/chaos/inject-latency.sh <app> [ms]` | Application performance |

`<app>` is one of `ecommerce`, `banking`, `food-delivery`, `student-portal`, or `support-tickets`.

To get back to a healthy state:

- `break-config.sh`, `shrink-limits.sh`, and `break-ingress.sh` take `--undo`.
- `./scripts/chaos/reset.sh <app>` clears injected latency and other in-app chaos.
- `bad-deploy.sh` prints the `kubectl` command that reverts it.

The [runbooks](docs/runbooks/) walk through each fix step by step, and [DevOps STAR scenarios](docs/devops-star-scenarios.md) describes the same incidents as production write-ups.

## 8. Destroy the lab

Teardown deletes the Ingresses first so the controller can release the ALB. It then removes the controller and the namespaces, and runs `terraform destroy`.

```bash
./scripts/teardown.sh
```

Afterward, check the AWS console for leftover ALBs, target groups, NAT Gateways, Elastic IPs, ECR repositories, or RDS instances.

## Where to find the config

| What | Where |
|---|---|
| Your lab settings (domain, region, nodes, DB size) | `terraform/terraform.tfvars`, created from [terraform.tfvars.example](terraform/terraform.tfvars.example) and gitignored |
| Terraform variables and defaults | [terraform/variables.tf](terraform/variables.tf) |
| AWS infrastructure | [terraform/](terraform/): `vpc.tf`, `eks.tf`, `ecr.tf`, `rds.tf`, `dns.tf`, `acm.tf`, `alb-controller.tf` |
| App runtime settings | `apps/<app>/k8s/configmap.yaml` |
| App Deployments, Services, autoscaling | `apps/<app>/k8s/` |
| Database schema and seed data | `apps/<app>/backend/sql/init.sql` |
| Database credentials | Secret `<app>-db-credentials` in each app namespace, generated by `setup.sh` and never stored in Git |
| Hostname routing | [ingress/](ingress/), one Ingress per app on the shared ALB |
| Namespaces, quotas, limit ranges | [namespaces/](namespaces/) |
| Access roles (RBAC) | [rbac/](rbac/), used by `setup.sh` and `scripts/users.sh` |
| Incident triggers | [scripts/chaos/](scripts/chaos/) |

Files that are generated locally and gitignored: `.lab-domain`, `terraform/*.tfstate` (contains the RDS master password), and `kubeconfigs/` (teammate access files). Never commit them.

## Repository layout

```text
apps/          Application source and Kubernetes manifests
docs/          Architecture, guides, incident scenarios, runbooks, and PDFs
ingress/       One hostname-based Ingress per application
namespaces/    Namespaces, quotas, and limit ranges
rbac/          Cluster access roles and per-user templates
scripts/       Setup, teardown, user access, and chaos triggers
terraform/     VPC, EKS, ECR, RDS, Route 53, IAM, and ALB controller
```

## Guides

- [Architecture](docs/architecture.md)
- [Connecting to a shared lab cluster](docs/connect-to-the-cluster.md) ([PDF](docs/pdf/connect-to-the-cluster.pdf))
- [Student guide](docs/student-guide.md)
- [Scenario test checklist](docs/testing-the-lab.md)
- [Runbooks](docs/runbooks/)
- [All PDFs](docs/pdf/)
