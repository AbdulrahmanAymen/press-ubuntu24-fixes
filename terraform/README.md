# Press Cluster Infrastructure (Terraform)

Provisions the 4 EC2 instances (`press`, `n1`, `m1`, `f1`) and their Elastic IPs and shared Security Group, matching the manual setup described in the [self-hosting guide](../GUIDE.md).

## What this creates

- 4x EC2 instances on Ubuntu 24.04 LTS (auto-resolves the latest AMI — no hardcoded, potentially stale AMI ID)
- 4x Elastic IPs, one per instance, associated immediately
- 1x shared Security Group: SSH (from your IP only), HTTP/HTTPS (public), and full internal traffic between the 4 servers

## What this does NOT do

This only builds the infrastructure layer. It does **not**:
- Install Frappe/Press, MariaDB, Docker, etc. (see the main guide's Part 5 onward)
- Apply any of the Ubuntu 24.04 dependency fixes (Ansible, pyOpenSSL, MariaDB role, etc.)
- Set up DNS (DuckDNS or otherwise) — you'll still register your subdomains manually against the IPs this outputs

Think of this as replacing Part 2 of the guide (manually launching 4 EC2 instances in the console) — everything from Part 3 onward is still done the same way.

## Prerequisites

- Terraform >= 1.5 installed
- AWS CLI configured with credentials that can create EC2/EIP/SecurityGroup resources (`aws configure`)
- An existing EC2 key pair already uploaded to AWS (this does NOT create a new key pair — it references one you already have)

## Usage

```bash
cp terraform.tfvars.example terraform.tfvars
```

Edit `terraform.tfvars` and fill in:
- `key_pair_name` — the name of your existing AWS key pair (not the local `.pem` filename, the name shown in EC2 → Key Pairs)
- `admin_ssh_cidr` — your IP address as a CIDR (run `curl ifconfig.me` to find it, then add `/32`)

Then:
```bash
terraform init
terraform plan
terraform apply
```

Type `yes` when prompted. After a minute or two, Terraform prints:
```
server_public_ips = { ... }
server_private_ips = { ... }
ssh_commands = { ... }
```

Use `server_public_ips` to register your DuckDNS (or real domain) A records, and `server_private_ips` when filling in each server's "Private IP" field inside the Press dashboard.

## Destroying everything

```bash
terraform destroy
```

⚠️ This deletes all 4 instances and their Elastic IPs permanently, along with anything installed on them. Only run this if you genuinely want to tear the whole cluster down and start over — there's no undo.

## Notes

- The AMI lookup always grabs the *latest* Ubuntu 24.04 AMI at the time you run `terraform apply`. If you re-apply months later and Canonical has published a newer point release, Terraform may want to replace your instances with the newer AMI — check `terraform plan` output before applying if that matters to you (add a specific AMI ID filter instead of `most_recent` if you want to pin a version permanently).
- Elastic IPs incur an hourly charge for any address in continuous use beyond a small free allowance — this is unavoidable with 4 always-on servers and applies regardless of Elastic vs. ephemeral IPs (see the main guide's Part 2.1 for details).
