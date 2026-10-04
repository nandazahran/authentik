#!/bin/bash
# quick-fixes.sh - Apply non-controversial fixes to README.md
# Run this to fix the minor technical issues found during verification

set -euo pipefail

echo "==> Applying quick fixes to Authentik assignment documentation"
echo

# Backup original
cp README.md README.md.backup
echo "✓ Backed up README.md to README.md.backup"

# Fix 1: Update Docker Compose URL to official current URL
echo "✓ Updating Docker Compose download URL to official docs URL"
sed -i 's|https://goauthentik.io/docker-compose.yml|https://docs.goauthentik.io/compose.yml|g' README.md

# Fix 2: Add missing reference URLs
echo "✓ Adding missing reference URLs"
sed -i 's|3. Caddy Documentation <!-- TODO: tambahkan tautan -->|3. [Caddy Documentation](https://caddyserver.com/docs/)|g' README.md
sed -i 's|4. IT-Tools <!-- TODO: tambahkan tautan -->|4. [IT-Tools](https://github.com/CorentinTh/it-tools)|g' README.md
sed -i 's|5. Memos Documentation <!-- TODO: tambahkan tautan -->|5. [Memos Documentation](https://www.usememos.com/docs)|g' README.md
sed -i 's|6. Keycloak Documentation <!-- TODO: tambahkan tautan -->|6. [Keycloak Documentation](https://www.keycloak.org/documentation)|g' README.md
sed -i 's|7. Authelia Documentation <!-- TODO: tambahkan tautan -->|7. [Authelia Documentation](https://www.authelia.com/)|g' README.md

echo
echo "==> Fixes applied successfully"
echo
echo "Changes made:"
echo "  1. Updated Docker Compose URL to docs.goauthentik.io/compose.yml"
echo "  2. Added 5 missing reference documentation links"
echo
echo "TODOs remaining: 24 (down from 29)"
echo
echo "Next steps (manual work required):"
echo "  - Add group member names (line 6)"
echo "  - Capture and add screenshots (8-12 needed)"
echo "  - Complete security analysis section (lines 278-284)"
echo "  - Complete comparison table installation difficulty row"
echo "  - Verify tech stack and add to line 16"
echo "  - Add architecture diagrams"
echo
echo "To revert changes: mv README.md.backup README.md"