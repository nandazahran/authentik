# Authentik Assignment TODO Checklist

Generated: 2026-10-04
Total TODOs: 29

## Critical (Must Complete Before Submission) — Priority 1

### Group Information
- [ ] **Line 6**: Fill in group name and member names
  - Template: `Kelompok X - Nama1, Nama2, Nama3, Nama4, Nama5`

### Screenshots (8-12 needed)
- [ ] **Line 134**: Installation step screenshots
  - VM creation
  - Docker installation output
  - docker-compose.yml download
  - First container startup
  - Initial setup page
  
- [ ] **Line 207**: User portal screenshot after login
- [ ] **Line 209**: User and group management interface
- [ ] **Line 217**: IT-Tools protected by forward auth (login redirect + after login)
- [ ] **Line 238**: Memos OIDC login flow

### Security Analysis (Assigned to Security Team Member)
- [ ] **Lines 278-284**: Complete security section
  - Brute force protection mechanisms
  - MFA options (TOTP, WebAuthn)
  - Audit log examples
  - Hardening recommendations
  - **Line 143**: nmap security scan results

### Documentation Links
- [x] **Line 305**: Caddy Documentation URL *(Fixed in quick-fixes.sh)*
- [x] **Line 306**: IT-Tools URL *(Fixed in quick-fixes.sh)*
- [x] **Line 307**: Memos Documentation URL *(Fixed in quick-fixes.sh)*
- [x] **Line 308**: Keycloak Documentation URL *(Fixed in quick-fixes.sh)*
- [x] **Line 309**: Authelia Documentation URL *(Fixed in quick-fixes.sh)*
- [ ] **Line 310**: Additional tutorial links used during setup

### Comparison Table
- [ ] **Line 295**: Complete "Kesulitan instalasi" row
  - Authentik: Mudah (Docker Compose, straightforward)
  - Keycloak: Sedang (Java setup, more configuration)
  - Authelia: Sedang (Config-driven, learning curve)

**Estimated time: 4 hours**

---

## Important (Should Complete for Quality) — Priority 2

### Technical Details
- [ ] **Line 15**: Add Authentik history
  - Founded year, main developers
  - Open source project background
  
- [ ] **Line 16**: Verify and document tech stack
  - Backend: Python with Django framework
  - Database: PostgreSQL
  - Cache/Queue: Check if Redis still used (line 33)
  - Worker: Celery or similar
  
- [ ] **Line 33**: Check current docker-compose.yml for Redis usage
  - Download and inspect latest compose file
  - Update documentation accordingly

### Visual Documentation
- [ ] **Line 34**: Create system architecture diagram
  - Browser → Caddy (reverse proxy)
  - Caddy → Authentik server/worker
  - Server → PostgreSQL database
  - Optional: Redis if confirmed
  
- [ ] **Line 64**: Create flow diagrams
  - Forward auth flow (IT-Tools)
  - OIDC flow (Memos)
  - Show differences visually

### Configuration Details
- [ ] **Line 150**: User and group creation steps with screenshots
  - Step-by-step in Authentik admin interface
  
- [ ] **Line 151**: MFA setup for admin
  - TOTP configuration
  - Or WebAuthn (passkey)
  
- [ ] **Line 152**: Branding and login flow customization
  - Where to change logo
  - How to customize login page
  
- [ ] **Line 153**: Email configuration (optional)
  - SMTP settings for password recovery
  
- [ ] **Lines 156-161**: Complete concept definitions
  - Flow: Complete explanation with examples
  - Stage: Detail with screenshot
  - Policy: Explain with use case
  - Provider: Detail each type
  - Application: Complete explanation
  - Outpost: When and why to use
  
- [ ] **Line 174**: Verify forward_auth block against latest Authentik docs
  - *(Note: Already verified during audit — matches exactly)*
  - Can mark complete or keep as reminder to check on updates
  
- [ ] **Line 175**: Optional CA certificate trust setup
  - How to extract Caddy CA cert
  - Import to browser
  - Import to Memos container if needed

### Personal Experience
- [ ] **Line 268**: Add pros based on actual deployment
  - What worked well
  - Positive surprises
  
- [ ] **Line 275**: Add cons based on actual deployment
  - Difficulties encountered
  - Areas for improvement

### Usage Documentation
- [ ] **Line 241**: MFA registration demo (TOTP and/or passkey)
- [ ] **Line 243**: Policy access control demo
  - Create policy
  - Bind to application
  - Show denial for non-member
  
- [ ] **Line 245**: Custom flow demo (signup or password recovery)
- [ ] **Line 247**: Audit log screenshots
  - Login success
  - Login failure
  - Policy denial

**Estimated time: 3 hours**

---

## Optional (Nice to Have) — Priority 3

### Advanced Automation
- [ ] **Line 197**: Blueprint YAML examples
  - Example for creating group
  - Example for IT-Tools application
  - Example for Memos application
  - How to apply blueprints
  
- [ ] **Line 200**: LXC deployment comparison
  - Proxmox helper script approach
  - Pros: lighter, snapshotting
  - Cons: less portable
  - When to choose each

### Edge Cases
- [ ] **Line 238**: Verify Memos field names in current version
  - Check if SSO field names changed
  - Update if needed
  
- [ ] **Line 239**: SSL troubleshooting note
  - When to enable network aliases
  - How to mount CA cert in Memos container
  - SSL_CERT_FILE environment variable

**Estimated time: 2 hours**

---

## Already Fixed (Verification Script Identified)

### Technical Accuracy
- [x] **Line 78**: System requirements match official docs
  - *(Verified: 2 CPU, 2 GB RAM = official)*
  
- [x] **Line 102**: Docker Compose URL
  - *(Can be updated with quick-fixes.sh script)*
  
- [x] Caddyfile forward_auth headers
  - *(Verified: exact match with official docs)*
  
- [x] Secret generation commands
  - *(Verified: match official docs)*
  
- [x] Docker installation commands
  - *(Verified: match official Docker docs)*

---

## Summary by Section

| Section | TODOs | Priority 1 | Priority 2 | Priority 3 |
|---------|-------|------------|------------|------------|
| Sekilas Tentang | 6 | 1 | 4 | 1 |
| Instalasi | 3 | 2 | 1 | 0 |
| Konfigurasi | 4 | 0 | 3 | 1 |
| Otomatisasi | 2 | 0 | 0 | 2 |
| Cara Pemakaian | 5 | 3 | 2 | 0 |
| Pembahasan | 3 | 0 | 2 | 1 |
| Referensi | 6 | 5 | 0 | 0 |
| **Total** | **29** | **11** | **12** | **6** |

After running quick-fixes.sh: **24 TODOs remaining**

---

## Recommended Workflow

### Session 1: Quick Wins (30 minutes)
1. Run `./quick-fixes.sh` to apply automated fixes
2. Add group member names (line 6)
3. Complete comparison table (line 295)
4. Add tutorial references if any (line 310)

### Session 2: Screenshots (90 minutes)
1. Ensure VM is running with Authentik installed
2. Capture all installation screenshots
3. Capture configuration interface screenshots
4. Capture demo application screenshots (IT-Tools, Memos)
5. Insert screenshots into README.md

### Session 3: Security Analysis (90 minutes)
1. Run nmap scan from external machine
2. Test brute force protection
3. Configure and test MFA
4. Review audit logs
5. Write security section with findings

### Session 4: Technical Details (60 minutes)
1. Research Authentik history and license
2. Download and check compose.yml for Redis
3. Document confirmed tech stack
4. Create architecture diagrams (can use mermaid or draw.io)

### Session 5: Polish (60 minutes)
1. Add personal experience notes
2. Complete concept definitions
3. Review all sections for consistency
4. Spell check and grammar review
5. Verify all links work

**Total estimated time: 5.5 hours across 5 sessions**

---

## Tools and Resources

### For Screenshots
- VM running Authentik stack
- Browser developer tools (for clean captures)
- Screenshot tool (Flameshot, Spectacle, or built-in)
- Image optimization (reduce file sizes before commit)

### For Diagrams
- Mermaid (text-based, renders in Markdown)
- Draw.io / Excalidraw (visual)
- Authentik official architecture docs for reference

### For Security Testing
- nmap (port scanning)
- Authentik admin interface (rate limiting settings)
- Authenticator app (for TOTP testing)
- Another machine on same network (for external testing)

### For Research
- Authentik GitHub repo: https://github.com/goauthentik/authentik
- Authentik official docs: https://docs.goauthentik.io/
- Current docker-compose.yml: https://docs.goauthentik.io/compose.yml

---

## Quality Checklist Before Submission

- [ ] All Priority 1 items complete
- [ ] At least 8 screenshots present
- [ ] All external links work
- [ ] No TODO comments in final version
- [ ] Group member names filled in
- [ ] Security analysis complete with evidence
- [ ] Comparison table fully filled
- [ ] Spell check passed
- [ ] Matches example.md structure
- [ ] README renders correctly in Markdown viewer