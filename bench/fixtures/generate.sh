#!/bin/sh
# Deterministic INI fixture generator.
#
# Produces small.ini, medium.ini, and large.ini in the same directory as
# this script. Inputs are fully deterministic (no timestamps, no randomness).
# Re-running produces byte-identical files.

set -eu

DIR="$(cd "$(dirname "$0")" && pwd)"

# small.ini: ~1 KB -- representative app config with several sections.
cat > "$DIR/small.ini" << 'EOF'
# Application configuration (small fixture for benchmarks)

[general]
name = my-app
version = 1.2.3
debug = false
log_level = info

[server]
host = 127.0.0.1
port = 8080
timeout = 30
max_connections = 100

[database]
host = localhost
port = 5432
name = appdb
user = appuser
password = secret
pool_size = 10
pool_timeout = 5

[cache]
backend = redis
host = localhost
port = 6379
ttl = 300
max_entries = 10000

[logging]
file = /var/log/app.log
level = warn
rotate = daily
max_size = 100
keep = 7
EOF

# medium.ini: ~30 KB -- git-style config with many remote/branch entries.
{
  printf '# Medium fixture: git-config-like with many sections\n\n'
  printf '[core]\n'
  printf '\trepositoryformatversion = 0\n'
  printf '\tfilemode = true\n'
  printf '\tbare = false\n'
  printf '\tlogallrefupdates = true\n\n'

  i=0
  while [ "$i" -lt 200 ]; do
    printf '[remote "origin-%d"]\n' "$i"
    printf '\turl = https://github.com/example/repo-%d.git\n' "$i"
    printf '\tfetch = +refs/heads/*:refs/remotes/origin-%d/*\n' "$i"
    printf '\tpushurl = git@github.com:example/repo-%d.git\n\n' "$i"
    i=$((i + 1))
  done

  i=0
  while [ "$i" -lt 100 ]; do
    printf '[branch "feature-%d"]\n' "$i"
    printf '\tremote = origin-0\n'
    printf '\tmerge = refs/heads/feature-%d\n\n' "$i"
    i=$((i + 1))
  done
} > "$DIR/medium.ini"

# large.ini: ~300 KB -- many sections with multiple keys each.
{
  printf '# Large fixture: many service sections\n\n'
  i=0
  while [ "$i" -lt 2000 ]; do
    printf '[service-%d]\n' "$i"
    printf 'name = service-%d\n' "$i"
    printf 'host = 10.0.%d.%d\n' "$((i / 256))" "$((i % 256))"
    printf 'port = %d\n' "$((8000 + i % 1000))"
    printf 'enabled = true\n'
    printf 'weight = %d\n' "$((i % 100))"
    printf 'timeout = 30\n'
    printf 'retries = 3\n\n'
    i=$((i + 1))
  done
} > "$DIR/large.ini"

echo "Generated: small.ini medium.ini large.ini"
