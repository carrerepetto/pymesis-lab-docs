#!/bin/bash
# Db2 pre-backup hook para backup.sh de lx1 (Ansible role: baseline)
set -euo pipefail

CONTAINER="db2server"
DB_NAME="sample"
CONTAINER_BACKUP_DIR="/database/backup"
DUMP_DIR="/opt/docker_dumps/db2"
KEEP_LOCAL=3

mkdir -p "$DUMP_DIR"

# Backup nativo online de Db2, dentro del contenedor
docker exec "$CONTAINER" su - db2inst1 -c "db2 backup db ${DB_NAME} to ${CONTAINER_BACKUP_DIR}"

# Ubicar el archivo recién generado y copiarlo afuera del contenedor
LATEST=$(docker exec "$CONTAINER" su - db2inst1 -c "ls -t ${CONTAINER_BACKUP_DIR}" | head -1)
docker cp "${CONTAINER}:${CONTAINER_BACKUP_DIR}/${LATEST}" "${DUMP_DIR}/${LATEST}"

# Purgar backups viejos dentro del volumen del contenedor (no crecer indefinidamente)
docker exec "$CONTAINER" su - db2inst1 -c \
  "cd ${CONTAINER_BACKUP_DIR} && ls -t | tail -n +\$(( ${KEEP_LOCAL} + 1 )) | xargs -r rm --"

# Purgar copias viejas locales en el dump dir (Restic ya guarda el historial real)
find "$DUMP_DIR" -type f -mtime +2 -delete
