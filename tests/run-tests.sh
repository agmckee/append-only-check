#!/bin/sh
# Integration tests for append-only-check. Creates throwaway repositories with
# a bare "origin" remote and runs the hook against staged changes.
#
#     sh tests/run-tests.sh

set -u

HOOK=$(cd "$(dirname "$0")/.." && pwd)/append-only-check
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
export GIT_AUTHOR_NAME=test GIT_AUTHOR_EMAIL=test@example.com
export GIT_COMMITTER_NAME=test GIT_COMMITTER_EMAIL=test@example.com

pass=0
fail=0
n=0

# Fresh clone with migrations already shipped on origin/main.
setup() {
    n=$((n + 1))
    origin=$WORK/origin$n.git
    repo=$WORK/repo$n
    git init -q --bare -b main "$origin"
    git init -q -b main "$repo"
    cd "$repo" || exit 1
    mkdir -p database/migrations app/Models
    printf 'database/migrations/\n' > .append-only-paths
    echo up1 > database/migrations/2024_01_01_create_users.php
    echo up2 > "database/migrations/2024_02_01_add phone.php"
    echo model > app/Models/User.php
    git add -A && git commit -q -m init
    git remote add origin "$origin"
    git push -q -u origin main
    git remote set-head origin main >/dev/null
    git checkout -q -b feature
}

run_hook() {
    out=$(sh "$HOOK" 2>&1)
    code=$?
}

check() { # description, expected exit code, expected warning (yes/no)
    if [ -n "$out" ]; then warned=yes; else warned=no; fi
    if [ "$code" = "$2" ] && [ "$warned" = "$3" ]; then
        pass=$((pass + 1))
        echo "ok   - $1"
    else
        fail=$((fail + 1))
        echo "FAIL - $1 (exit=$code, warned=$warned)"
        printf '%s\n' "$out" | sed 's/^/       | /'
    fi
}

check_output_contains() {
    if printf '%s\n' "$out" | grep -qF -- "$2"; then
        pass=$((pass + 1))
        echo "ok   - $1"
    else
        fail=$((fail + 1))
        echo "FAIL - $1 (missing: $2)"
        printf '%s\n' "$out" | sed 's/^/       | /'
    fi
}

# --- tests -------------------------------------------------------------------

setup
echo new > database/migrations/2024_03_01_new.php
git add -A; run_hook
check "adding a new migration is silent" 0 no

setup
echo changed >> database/migrations/2024_01_01_create_users.php
git add -A; run_hook
check "modifying a shipped migration warns" 0 yes
check_output_contains "warning names the file" \
    "modified: database/migrations/2024_01_01_create_users.php"

setup
git rm -q database/migrations/2024_01_01_create_users.php; run_hook
check "deleting a shipped migration warns" 0 yes
check_output_contains "warning says deleted" "deleted:  database/migrations/2024_01_01_create_users.php"

setup
git mv database/migrations/2024_01_01_create_users.php \
    database/migrations/2024_01_02_create_users.php; run_hook
check "renaming a shipped migration warns" 0 yes

setup
echo changed >> "database/migrations/2024_02_01_add phone.php"
git add -A; run_hook
check_output_contains "paths with spaces are reported" "2024_02_01_add phone.php"

setup
echo changed >> app/Models/User.php
git add -A; run_hook
check "modifying a file outside protected paths is silent" 0 no

setup
echo mine > database/migrations/2024_03_01_mine.php
git add -A && git commit -q -m "add my migration"
echo fixed >> database/migrations/2024_03_01_mine.php
git add -A; run_hook
check "editing an unshipped migration on your branch is silent" 0 no

setup
echo oops >> database/migrations/2024_01_01_create_users.php
git add -A && git commit -q -m "bad edit" --no-verify
git checkout -q origin/main -- database/migrations/2024_01_01_create_users.php
run_hook
check "reverting a shipped migration to its original content is silent" 0 no

setup
git config appendOnly.strict true
echo changed >> database/migrations/2024_01_01_create_users.php
git add -A; run_hook
check "strict mode blocks the commit" 1 yes

setup
printf '# comment\r\n\r\n  database/migrations  \r\n' > .append-only-paths
echo changed >> database/migrations/2024_01_01_create_users.php
git add -A; run_hook
check "CRLF, comments, whitespace and missing slash in config" 0 yes

setup
printf '*/migrations/\n' > .append-only-paths
mkdir -p blog/migrations
echo m > blog/migrations/0001_initial.py
git add -A && git commit -q -m blog && git push -q origin feature:main
echo changed >> blog/migrations/0001_initial.py
git add -A; run_hook
check "glob pattern matches Django app migrations" 0 yes

setup
rm .append-only-paths
echo changed >> database/migrations/2024_01_01_create_users.php
git add -A; run_hook
check "no config file means no checks" 0 no

setup
git remote remove origin
echo changed >> database/migrations/2024_01_01_create_users.php
git add -A; run_hook
check "without a remote, committed files are treated as shipped" 0 yes

setup
git config appendOnly.baseRef release
git branch -q release main
echo changed >> database/migrations/2024_01_01_create_users.php
git add -A; run_hook
check "appendOnly.baseRef is honoured" 0 yes

setup
git config appendOnly.baseRef no-such-ref
echo changed >> database/migrations/2024_01_01_create_users.php
git add -A; run_hook
check_output_contains "unknown baseRef is reported" "no-such-ref' not found"

setup
printf 'legacy sql/\n' > .append-only-paths
mkdir "legacy sql" && echo up > "legacy sql/0001.sql"
git add -A && git commit -q -m legacy && git push -q origin feature:main
echo changed >> "legacy sql/0001.sql"
git add -A; run_hook
check "pattern containing a space matches" 0 yes

# A path starting with "<digit>:" must not be misread as an index stage number.
setup
printf '1:legacy/\n' > .append-only-paths
mkdir 1:legacy && echo up > 1:legacy/0001.sql
git add -A && git commit -q -m legacy && git push -q origin feature:main
echo oops >> 1:legacy/0001.sql
git add -A && git commit -q -m "bad edit" --no-verify
git checkout -q origin/main -- 1:legacy/0001.sql
run_hook
check "reverting a shipped file under a digit-colon path is silent" 0 no

# End to end: installed as a real hook, the commit succeeds with the warning.
setup
mkdir .githooks && cp "$HOOK" .githooks/pre-commit && chmod +x .githooks/pre-commit
git config core.hooksPath .githooks
echo changed >> database/migrations/2024_01_01_create_users.php
git add database/migrations
out=$(git commit -m "edit migration" 2>&1); code=$?
check "real git commit succeeds and shows the warning" 0 yes
if [ "$(git log -1 --format=%s)" = "edit migration" ]; then
    pass=$((pass + 1)); echo "ok   - commit was recorded"
else
    fail=$((fail + 1)); echo "FAIL - commit was not recorded"
fi

echo
echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
