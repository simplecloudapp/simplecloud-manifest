#!/bin/bash
# Prepares a SimpleCloud self-hosting directory: downloads compose.yaml and
# writes a .env file with generated secrets and NATS keys.
#
# Usage: setup.sh <domain>
# Example: curl -fsSL https://raw.githubusercontent.com/simplecloudapp/simplecloud-manifest/main/self-hosting/setup.sh | bash -s -- example.com

set -euo pipefail

COMPOSE_URL="https://raw.githubusercontent.com/simplecloudapp/simplecloud-manifest/main/self-hosting/compose.yaml"
NATS_BOX_IMAGE="natsio/nats-box:0.20.1"

domain="${1:-}"
if [ -z "$domain" ]; then
    echo "Usage: setup.sh <domain>" >&2
    exit 1
fi

if [ -e .env ]; then
    echo "A .env file already exists here. Remove it to generate new secrets." >&2
    exit 1
fi

command -v docker >/dev/null || { echo "Docker is required." >&2; exit 1; }

hex() { head -c 32 /dev/urandom | od -An -tx1 | tr -d ' \n'; }

# Prints the seed and the public key of a new NATS key, one per line.
nkey() { docker run --rm "$NATS_BOX_IMAGE" nk -gen "$1" -pubout; }

{ read -r issuer_seed; read -r issuer_public; } < <(nkey account)
{ read -r user_seed; read -r user_public; } < <(nkey user)

curl -fsSL "$COMPOSE_URL" -o compose.yaml

umask 077
cat > .env <<EOF
DOMAIN=$domain

# Login providers. Fill in at least one.
GOOGLE_CLIENT_ID=
GOOGLE_CLIENT_SECRET=
GITHUB_CLIENT_ID=
GITHUB_CLIENT_SECRET=
DISCORD_CLIENT_ID=
DISCORD_CLIENT_SECRET=

# Generated secrets. Keep this file private.
POSTGRES_PASSWORD=$(hex)
VALKEY_PASSWORD=$(hex)
CLICKHOUSE_PASSWORD=$(hex)
ENVIRONMENT_VARIABLE_ENCRYPTION_KEY=$(head -c 32 /dev/urandom | base64)
BETTER_AUTH_SECRET=$(hex)
AUTH_INTERNAL_SECRET=$(hex)
NETWORK_CREDENTIALS_SECRET=$(hex)
NATS_ISSUER_SEED=$issuer_seed
NATS_ISSUER_PUBLIC_KEY=$issuer_public
NATS_USER_SEED=$user_seed
NATS_USER_PUBLIC_KEY=$user_public
EOF

echo "Created compose.yaml and .env for $domain."
echo "Add a login provider to .env, then run: docker compose up -d"
