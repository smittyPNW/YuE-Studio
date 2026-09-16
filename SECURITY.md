# Security and privacy

Do not post credentials, audio you cannot share, personal file paths, or raw support logs in public issues. For a vulnerability, use this repository's private vulnerability reporting feature when available.

Generation dependencies and model weights are downloaded during setup. Generation runs locally afterward; the application is not a hosted music service. Dependency installers and model-hub clients are separate components with their own behavior. Do not infer air-gapped guarantees from “local.”

No API key is required for the bundled public generation path. ReSoul's engine and preset catalog are private and intentionally excluded. The release process scans public files and the Git history before pushing. Automated scanners can miss secrets; also review staged content and release assets manually.

If a secret is accidentally published, revoke/rotate it promptly and follow GitHub's sensitive-data removal guidance. Removing only the current file does not remove Git history.
