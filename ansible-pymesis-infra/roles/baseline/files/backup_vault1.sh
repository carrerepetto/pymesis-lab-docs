#!/bin/bash
set -e

export VAULT_ADDR='https://vault1.pymesis.lab:8200'
DUMP_DIR="/opt/backup_dumps"
ROLE_ID_FILE="/root/.vault-backup-role-id"
SECRET_ID_FILE="/root/.vault-backup-secret-id"

mkdir -p "$DUMP_DIR"

ROLE_ID=$(cat "$ROLE_ID_FILE")
SECRET_ID=$(cat "$SECRET_ID_FILE")

export VAULT_TOKEN=$(vault write -field=token auth/approle/login role_id="$ROLE_ID" secret_id="$SECRET_ID")

vault operator raft snapshot save "$DUMP_DIR/raft-snapshot.snap"

vault token revoke -self
