# append-only-check

A Git pre-commit hook that warns developers when they modify, delete or rename
files in directories that should only ever be **added to**, such as Laravel
`database/migrations/`, Alembic `versions/` or Django `*/migrations/`.

Editing a migration that has already run elsewhere has no effect on those
databases and makes environments drift. The fix should be a new migration. The
hook explains this when someone commits, so the conversation happens before it
reaches review.

```
WARNING: this commit changes files in append-only paths

    modified: database/migrations/2024_01_01_create_users_table.php

  These paths are listed in .append-only-paths. Files there (e.g. database
  migrations) may already have been run on other machines or in
  production, so editing them retrospectively has no effect there and
  makes environments drift. Add a NEW file that makes the correction
  instead.

  The commit will go ahead. If this is intentional, please explain
  why in the pull request so reviewers aren't surprised.
```

## Behaviour

- **Advisory by default.** The commit always goes ahead. Set
  `git config appendOnly.strict true` to block instead (`--no-verify` still
  overrides).
- **Only "shipped" files are protected.** A file counts as shipped if it exists
  on the base ref: the remote's default branch (`origin/HEAD`, else
  `origin/main`, else `origin/master`). A developer fixing a migration they
  added earlier on the same unmerged branch is doing the right thing and gets
  no warning. To use a different base, set e.g.
  `git config appendOnly.baseRef origin/develop`. If no base ref can be found,
  every already-committed file under a protected path is treated as shipped.
- **Adding files is always silent.** So is restoring a shipped file to its
  original content.
- **Renames warn**, because to the database a renamed migration is a
  new, unrun migration.
- **No `.append-only-paths` file means no checks**, so it is safe to install
  globally.

## Configuring a project

Copy `append-only-paths.example` to `.append-only-paths` in the project root,
adjust it, and commit it:

```
database/migrations/
```

Each line is a file or directory, optionally with shell globs (`*` matches
across `/`). Comments (`#`) and blank lines are ignored.

## Installing the hook

The script is plain POSIX `sh` with no dependencies beyond Git, so it runs on
Linux, macOS and Git for Windows.

### Plain Git (committed hooks directory)

```sh
mkdir -p .githooks
cp /path/to/append-only-check .githooks/pre-commit
chmod +x .githooks/pre-commit
git add .githooks .append-only-paths
```

Each developer runs `git config core.hooksPath .githooks` once. To avoid
relying on that, wire it into a setup step that already runs. For Laravel,
add it to `composer.json`:

```json
"scripts": {
    "post-install-cmd": ["git config core.hooksPath .githooks || true"]
}
```

If the project already has a `pre-commit` hook, save this script as
`.githooks/append-only-check` and call it from the existing hook instead.

### pre-commit framework (typical for Python / Alembic projects)

Host this repository somewhere your projects can reach, then add to the
project's `.pre-commit-config.yaml`:

```yaml
repos:
  - repo: https://git.example.com/your-org/append-only-check
    rev: v1.0.0
    hooks:
      - id: append-only-check
```

### Husky (Laravel projects with a `package.json`)

Copy the script into the repo (e.g. `scripts/append-only-check`) and add a line
to `.husky/pre-commit`:

```sh
sh scripts/append-only-check
```

## Limitations

- Client-side hooks are opt-in and skippable (`--no-verify`, or simply never
  installed). They catch honest mistakes early but are not a guarantee. If
  you need enforcement, run the same rule in CI or a server-side hook.
- Some Git GUIs and IDEs only show hook output when the hook fails. In
  advisory mode, developers who commit from those tools may not see the
  warning. Strict mode makes it visible everywhere.
- The base ref is only as fresh as the developer's last `git fetch`.

## Tests

```sh
sh tests/run-tests.sh
```
