set -eu
# dbdump — ИЗПЪЛНЯВА СЕ ВЪТРЕ в job контейнер с образа tools/pgtools (Backup
# workflow-ът го подава като команда на dbinit job-а). Env от dbinit job-а:
# PGHOST, TARGET_DB, MIGRATOR_ROLE, MIGRATOR_PASSWORD; workflow-ът добавя
# UPLOAD_URL (временна връзка САМО за запис към един blob в Storage).
#
# pg_dump -Fc като ролята-собственик (вижда всички редове: таблиците не са с
# FORCE ROW LEVEL SECURITY), проверка на дъмпа (pg_restore --list), качване.
#
# Без двоен долар и без "долар + скоба" (Kubernetes ги преобразува).

echo "dbdump: база $TARGET_DB, като $MIGRATOR_ROLE"

PGUSER="$MIGRATOR_ROLE" PGPASSWORD="$MIGRATOR_PASSWORD" pg_dump -Fc -d "$TARGET_DB" -f /tmp/backup.dump
pg_restore --list /tmp/backup.dump > /tmp/backup.list
echo "dbdump: дъмпът е проверен (`wc -l < /tmp/backup.list` обекта, `wc -c < /tmp/backup.dump` байта)"

curl -sS --fail -X PUT -H "x-ms-blob-type: BlockBlob" --data-binary @/tmp/backup.dump "$UPLOAD_URL"
rm -f /tmp/backup.dump /tmp/backup.list

echo "dbdump: готово"
