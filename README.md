# Zero-Downtime EC2 Migration with Terraform

Migrate from a `t3.small` to a `t3.medium` EC2 instance behind an Application Load Balancer — with zero downtime.

## Architecture

```
Internet → ALB (port 80) → Target Group → EC2 Instance(s)
```

- **VPC** with 2 public subnets in different Availability Zones
- **ALB** distributes HTTP traffic to healthy targets
- **Phase 1**: `t3.small` in Subnet 1 serves traffic
- **Phase 2**: `t3.medium` in Subnet 2 is added, then `t3.small` is removed — no dropped requests

## File Structure

| File | Description |
|------|-------------|
| `main.tf` | All AWS resources (VPC, subnets, ALB, security groups, EC2) |
| `variables.tf` | Input variable definitions |
| `terraform.tfvars` | Variable values — **edit this before applying** |
| `outputs.tf` | ALB DNS name output |
| `user_data.sh` | Installs and starts nginx on Amazon Linux 2023 |

## Prerequisites

- [Terraform](https://developer.hashicorp.com/terraform/install) >= 1.0
- AWS CLI configured with valid credentials
- An EC2 key pair created in your target region

## Setup

1. **Clone the repo**

   ```bash
   git clone https://github.com/<your-username>/zero-downtime-ec2-migration.git
   cd zero-downtime-ec2-migration
   ```

2. **Edit `terraform.tfvars`** with your actual values

   ```hcl
   region          = "us-east-1"
   vpc_cidr        = "10.0.0.0/16"
   subnet_cidr_az1 = "10.0.1.0/24"
   subnet_cidr_az2 = "10.0.2.0/24"
   ami_id          = "ami-0c101f26f147fa7fd"   # Amazon Linux 2023 for your region
   key_name        = "your-key-pair-name"
   your_ip         = "YOUR_PUBLIC_IP/32"        # e.g. 203.0.113.10/32
   ```

3. **Initialize and deploy**

   ```bash
   terraform init
   terraform plan
   terraform apply
   ```

4. **Get the ALB DNS**

   ```bash
   terraform output alb_dns
   ```

5. **Test** — open `http://<ALB_DNS>` in your browser. You should see the nginx welcome page.

## Migration (Phase 2)

1. Open `main.tf` and **uncomment** the `aws_instance.t3_medium` and `aws_lb_target_group_attachment.t3_medium` blocks at the bottom of the file.

2. Apply — both instances now receive traffic:

   ```bash
   terraform apply
   ```

3. Verify both targets are healthy in the target group, then **comment out or remove** the `aws_instance.t3_small` and `aws_lb_target_group_attachment.t3_small` blocks.

4. Apply again — traffic shifts entirely to `t3.medium`:

   ```bash
   terraform apply
   ```

### Verify Zero Downtime

Start a curl loop **before** you begin the migration:

```bash
while true; do curl -s -o /dev/null -w "%{http_code}\n" http://<ALB_DNS>; sleep 2; done | tee migration.log
```

After the migration is complete, check for any non-200 responses:

```bash
grep -v 200 migration.log
```

Empty output = zero downtime. ✅

## Security

- **ALB Security Group**: allows port 80 from `0.0.0.0/0` (public-facing)
- **EC2 Security Group**: allows port 80 **only from the ALB security group** (not from the internet directly), and port 22 only from your IP

## Cleanup

```bash
terraform destroy
```

## License

MIT
