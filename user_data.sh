#!/bin/bash
# -----------------------------------------------------------------------------
# User Data Script — Install and start nginx on Amazon Linux 2023 (uses dnf)
# -----------------------------------------------------------------------------

# Update all packages
dnf update -y

# Install nginx
dnf install -y nginx

# Start nginx and enable it to start on boot
systemctl start nginx
systemctl enable nginx
