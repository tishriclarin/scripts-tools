# Contributing to scripts-tools

This repository holds independent scripts and tools, not just Cacti.

## Web-server standard
- **NGINX only** for all web-serving projects, examples and deployments.
- PHP applications use **NGINX + PHP-FPM**.
- Do not install or configure Apache. Verify package dependency plans.
- Expose login screens only through HTTPS. Keep sensitive data private.
- Put each new tool in its own directory with documentation and tests.
- Never commit production passwords, SNMP secrets or customer data.
