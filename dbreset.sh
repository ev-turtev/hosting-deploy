set -eu
# dbreset — ИЗПЪЛНЯВА СЕ ВЪТРЕ в dbinit контейнера (restore-db.sh го подава
# като команда). Env от dbinit job-а: PGHOST, PGUSER, PGPASSWORD, PGDATABASE,
# TARGET_DB, MIGRATOR_ROLE.
#
# Изтрива базата на приложението, за да се зареди наново от дъмп. РОЛИТЕ
# ОСТАВАТ (паролите им са в Key Vault и приложението ги ползва).
#   1. базата се затваря за нови връзки (ALLOW_CONNECTIONS false)
#   2. чака до 2 минути старите да се затворят (pool-ът на приложението
#      затваря неактивните сам; администраторът на сървъра не може да ги прекъсне)
#   3. DROP DATABASE
# При КАКВАТО И ДА Е грешка преди DROP базата се отваря пак — нищо не е изтрито.
# После restore-db.sh пуска dbinit (създава я наново) и dbrestore.
#
# psql променливите (:'db') се заместват само в SQL от входа, не в -c —
# затова SQL-ът е през stdin. Без двоен долар и без "долар + скоба"
# (Kubernetes ги преобразува).

echo "dbreset: база $TARGET_DB на $PGHOST"

reopen() {
  echo 'SELECT EXISTS (SELECT 1 FROM pg_database WHERE datname = :'"'"'db'"'"') AS has_db \gset
\if :has_db
  ALTER DATABASE :"db" WITH ALLOW_CONNECTIONS true;
\endif' | psql -q -v db="$TARGET_DB" || true
}
dropped=no
on_exit() {
  if [ "$dropped" = "no" ]; then
    reopen
    echo "dbreset: прекъснато — базата е отворена пак, НИЩО не е изтрито" >&2
  fi
}
trap on_exit EXIT

psql -v ON_ERROR_STOP=1 -v db="$TARGET_DB" <<'SQL'
SELECT EXISTS (SELECT 1 FROM pg_database WHERE datname = :'db') AS has_db \gset
\if :has_db
  ALTER DATABASE :"db" WITH ALLOW_CONNECTIONS false;
  \echo dbreset: базата е затворена за нови връзки
\else
  \echo dbreset: базата я няма
\endif
SQL

i=0
n=1
while [ "$i" -lt 24 ]; do
  n=`echo "SELECT count(*) FROM pg_stat_activity WHERE datname = :'db' AND pid <> pg_backend_pid()" | psql -At -v ON_ERROR_STOP=1 -v db="$TARGET_DB"`
  [ "$n" = "0" ] && break
  echo "dbreset: $n отворени връзки, чакам..."
  sleep 5
  i=`expr $i + 1`
done
if [ "$n" != "0" ]; then
  echo "dbreset: връзките не се затвориха за 2 минути" >&2
  exit 1
fi

psql -v ON_ERROR_STOP=1 -v db="$TARGET_DB" <<'SQL'
SELECT EXISTS (SELECT 1 FROM pg_database WHERE datname = :'db') AS has_db \gset
\if :has_db
  DROP DATABASE :"db";
  \echo dbreset: базата е изтрита
\endif
SQL
dropped=yes

echo "dbreset: готово"
