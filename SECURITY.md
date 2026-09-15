# Security Policy

This repository follows the FractalSQLabs organization-wide security
policy. The full policy — reporting channels, supported versions,
disclosure timeline, scope, and artifact-integrity verification — is
maintained at:

> <https://github.com/FractalSQLabs/.github/blob/main/SECURITY.md>

## Quick reference

**To report a vulnerability:**

1. **Preferred: GitHub private vulnerability reporting.** Go to this
   repository's **Security** tab → **"Report a vulnerability"**. The
   advisory is private and visible only to maintainers.
2. **Email:** `security@fractalsqlabs.com`

**Do not open public GitHub issues** for security-sensitive reports.

We acknowledge valid reports within **3 business days** and follow a
**90-day coordinated disclosure window**. See the org-wide policy for
the full timeline, scope (in/out), and what we commit to in return.

## Supported versions

| Version | Supported |
| ------- | :-------: |
| 1.x     | ✅        |
| < 1.0   | ❌        |

## Artifact integrity

Every release artifact ships with a Syft SBOM, a Sigstore signature,
and a GitHub build-provenance attestation. Verification commands and
the full third-party component ledger are in the org-wide policy.
