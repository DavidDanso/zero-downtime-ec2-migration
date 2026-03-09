# -----------------------------------------------------------------------------
# Outputs
# -----------------------------------------------------------------------------

output "alb_dns" {
  description = "DNS name of the Application Load Balancer"
  value       = aws_lb.main.dns_name
}

# =============================================================================
# Validation Commands
# =============================================================================
#
# 1. Get ALB DNS:        terraform output alb_dns
#
# 2. Verify nginx:       ssh into t3.small → systemctl status nginx
#
# 3. Start curl loop:    while true; do curl -s -o /dev/null -w "%{http_code}\n" \
#                        http://<ALB_DNS>; sleep 2; done | tee migration.log
#
# 4. After migration:    grep -v 200 migration.log (output must be empty)
#
