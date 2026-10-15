set -eu
# dbrestore — ИЗПЪЛНЯВА СЕ ВЪТРЕ в dbinit контейнера (restore-db.sh го подава
# като команда), СЛЕД dbreset + dbinit (базата е нова и празна). Env от dbinit
# job-а: PGHOST, TARGET_DB, MIGRATOR_ROLE, MIGRATOR_PASSWORD; restore-db.sh
# добавя DUMP_URL (временна връзка само за четене към дъмпа в Storage) и
# APP_ROLE (приложната роля — получава CONNECT към базата).
#
# Зарежда дъмп (pg_dump -Fc) като ролята-собственик на базата:
#   - обектите стават нейни (--no-owner) — както са създадени от миграциите;
#   - правата (GRANT на приложната роля) и default privileges се пазят;
#   - разширенията са създадени от dbinit (администратора) — техните редове
#     (EXTENSION, COMMENT - EXTENSION) се пропускат: собственикът на базата
#     няма право върху тях;
#   - обект по обект, в 2 паралелни потока (--jobs): големи бази (хиляди таблици)
#     не се събират в една транзакция (заключванията). При грешка базата остава
#     ЧАСТИЧНО заредена — Restore се пуска пак (започва с изтриване).
#
# Без двоен долар и без "долар + скоба" (Kubernetes ги преобразува).

echo "dbrestore: база $TARGET_DB, като $MIGRATOR_ROLE"

wget -q -O /tmp/restore.dump "$DUMP_URL"
echo "dbrestore: дъмпът е изтеглен (`wc -c < /tmp/restore.dump` байта)"

# Списъкът на дъмпа без разширенията ("EXTENSION - citext", "COMMENT - EXTENSION
# citext"); коментарите по таблици и колони ("COMMENT public TABLE ...") остават.
pg_restore -l /tmp/restore.dump > /tmp/restore.all
grep -v -E ' (EXTENSION - |COMMENT - EXTENSION )' /tmp/restore.all > /tmp/restore.list || true
grep -E ' (EXTENSION - |COMMENT - EXTENSION )' /tmp/restore.all | sed 's/^/dbrestore: пропуснато (създадено от dbinit): /' || true

# Ролите НЕ са в pg_dump (общи са за сървъра). Дъмпът обаче ги споменава —
# в правата (GRANT ... TO), правилата за сигурност (CREATE POLICY ... TO) и
# default privileges. Липсващите се създават преди зареждането като роли БЕЗ
# вход (NOLOGIN), от ролята-собственик — иначе pg_restore пада с "role ... does
# not exist". Нужна ли е на някоя вход с парола — това е работа на миграциите
# на приложението; тук само се изписва.
pg_restore --schema-only --use-list=/tmp/restore.list -f /tmp/restore.schema.sql /tmp/restore.dump
{
  grep -E '^(CREATE POLICY |GRANT |ALTER DEFAULT PRIVILEGES )' /tmp/restore.schema.sql | sed -n 's/.* TO \(.*\)$/\1/p'
  grep -E '^(REVOKE |ALTER DEFAULT PRIVILEGES .* REVOKE )' /tmp/restore.schema.sql | sed -n 's/.* FROM \(.*\)$/\1/p'
  grep -E '^ALTER DEFAULT PRIVILEGES FOR ROLE ' /tmp/restore.schema.sql | sed -n 's/^ALTER DEFAULT PRIVILEGES FOR ROLE \([^ ]*\) .*/\1/p'
} | sed -e 's/ USING .*//' -e 's/ WITH CHECK .*//' -e 's/ WITH GRANT OPTION.*//' -e 's/ GRANTED BY .*//' -e 's/;.*//' \
  | tr ',' '\n' | sed -e 's/^ *//' -e 's/ *$//' -e 's/"//g' \
  | grep -E '^[^[:space:]]+$' | grep -viE '^(public|current_user|session_user|current_role)$' \
  | sort -u > /tmp/restore.roles || true
# "ALTER DEFAULT PRIVILEGES FOR ROLE X" изисква ролята-собственик да е ЧЛЕН на X
# (в PostgreSQL 16 създателят на роля не е член с права по подразбиране).
grep -E '^ALTER DEFAULT PRIVILEGES FOR ROLE ' /tmp/restore.schema.sql \
  | sed -n 's/^ALTER DEFAULT PRIVILEGES FOR ROLE \([^ ]*\) .*/\1/p' | sed -e 's/"//g' \
  | grep -vx "$MIGRATOR_ROLE" | sort -u > /tmp/restore.forroles || true
rm -f /tmp/restore.schema.sql
echo "dbrestore: роли, споменати в дъмпа: `tr '\n' ' ' < /tmp/restore.roles`"
while read -r r; do
  [ -n "$r" ] || continue
  printf '%s\n' \
    "SELECT NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = :'r') AS missing \\gset" \
    '\if :missing' \
    '  CREATE ROLE :"r" NOLOGIN;' \
    '  \echo dbrestore: СЪЗДАДЕНА липсваща роля (NOLOGIN) :r' \
    '\endif' \
    | PGUSER="$MIGRATOR_ROLE" PGPASSWORD="$MIGRATOR_PASSWORD" psql -q -v ON_ERROR_STOP=1 -v r="$r" -d "$TARGET_DB"
done < /tmp/restore.roles
while read -r r; do
  [ -n "$r" ] || continue
  printf '%s\n' \
    "SELECT NOT pg_has_role(current_user, :'r', 'USAGE') AS need \\gset" \
    '\if :need' \
    '  GRANT :"r" TO CURRENT_USER WITH INHERIT TRUE, SET TRUE;' \
    '  \echo dbrestore: собственикът стана член на :r (заради default privileges)' \
    '\endif' \
    | PGUSER="$MIGRATOR_ROLE" PGPASSWORD="$MIGRATOR_PASSWORD" psql -q -v ON_ERROR_STOP=1 -v r="$r" -d "$TARGET_DB"
done < /tmp/restore.forroles
rm -f /tmp/restore.roles /tmp/restore.forroles

# Без --exit-on-error: зарежда докрай и СЪБИРА всички грешки — едно пускане
# показва всичко (иначе спира на първата, често след десетки минути данни).
# Грешка има ли — изписват се групирани и job-ът завършва с грешка.
PGUSER="$MIGRATOR_ROLE" PGPASSWORD="$MIGRATOR_PASSWORD" pg_restore \
  --dbname="$TARGET_DB" --use-list=/tmp/restore.list \
  --no-owner --jobs=2 /tmp/restore.dump 2> /tmp/restore.err || true
# При --jobs двата потока пишат грешките преплетени ("pg_restore:pg_restore:
# error: error: ...") — затова ERROR: се търси навсякъде в реда, а броят е от
# последния ред "errors ignored on restore: N".
if grep -q 'ERROR:\|errors ignored on restore\|pg_restore: error' /tmp/restore.err; then
  echo "dbrestore: ГРЕШКИ при зареждането — `grep -o 'errors ignored on restore: [0-9]*' /tmp/restore.err | tail -1`. По вид:" >&2
  grep -o 'ERROR:  .*' /tmp/restore.err | sed -e 's/"[^"]*"/"…"/g' | sort | uniq -c | sort -rn | head -30 >&2
  echo "dbrestore: първите заявки с грешка:" >&2
  grep '^Command was' /tmp/restore.err | head -10 >&2
  grep -v 'ERROR:\|^Command was\|^HINT\|^DETAIL\|^ \|^$\|errors ignored' /tmp/restore.err | head -10 >&2
  rm -f /tmp/restore.err
  exit 1
fi
rm -f /tmp/restore.err

rm -f /tmp/restore.dump /tmp/restore.all /tmp/restore.list

# Правата НА НИВО БАЗА не са в pg_dump (на стария сървър ги е дала миграция,
# напр. 0002 на tteam-core), а dbinit е спрял CONNECT за всички — приложната
# роля получава CONNECT наново. SQL-ът е през stdin: psql заменя :"..." само там.
if [ -n "${APP_ROLE:-}" ]; then
  echo 'GRANT CONNECT ON DATABASE :"db" TO :"approle"' | PGUSER="$MIGRATOR_ROLE" PGPASSWORD="$MIGRATOR_PASSWORD" \
    psql -q -v ON_ERROR_STOP=1 -v db="$TARGET_DB" -v approle="$APP_ROLE" -d "$TARGET_DB"
  echo "dbrestore: CONNECT за $APP_ROLE"
fi

PGUSER="$MIGRATOR_ROLE" PGPASSWORD="$MIGRATOR_PASSWORD" psql -At -d "$TARGET_DB" -c \
  "SELECT 'dbrestore: таблици ' || count(*) FROM pg_tables WHERE schemaname = 'public'"
PGUSER="$MIGRATOR_ROLE" PGPASSWORD="$MIGRATOR_PASSWORD" psql -At -d "$TARGET_DB" -c \
  "SELECT 'dbrestore: последна миграция в дъмпа ' || max(version) FROM schema_migrations" 2>/dev/null || true

echo "dbrestore: готово"
