# Security reports

Report a suspected vulnerability through [GitHub private vulnerability reporting](https://github.com/BuildThingsThatBuildthings/goodest-notes/security/advisories/new). Include the affected release, component, and expected permission boundary. Redact keys, notebook contents, device identifiers, and personal information.

The workspace owner key grants administrative access. Store it separately from project-scoped chat and device credentials. Keep PostgreSQL dumps, Convex exports, iPad backups, signing credentials, and deployment environment files outside the repository.

Owners can revoke individual chat and device grants in the web workspace. If a provider key is disclosed, revoke it with the provider and replace the server environment value. If the workspace owner key is disclosed, rotate it on the server and review existing grants and queued tasks.
