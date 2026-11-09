#!/bin/sh
# Prints fresh secrets in .env format. Usage: ./gen-secrets.sh >> .env && chmod 600 .env
set -eu
echo "JWT_SECRET=$(openssl rand -hex 32)"
echo "CSRF_SECRET=$(openssl rand -base64 32)"
echo "API_KEY_HASH_PEPPER=$(openssl rand -hex 32)"
