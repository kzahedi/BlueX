#!/bin/sh
# Installs the repo's git hooks. Safe to re-run.
set -e
root=$(git rev-parse --show-toplevel)
cp "$root/tools/hooks/pre-commit" "$root/.git/hooks/pre-commit"
chmod +x "$root/.git/hooks/pre-commit"
echo "installed: .git/hooks/pre-commit (golden rule: no scraped data in git)"
