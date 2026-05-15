# Security Policy

## Supported Versions

Only the latest version of Anicat is supported for security updates. Please ensure you are running the latest version by checking the Dashboard sidebar for the update indicator.

## Reporting a Vulnerability

If you discover a potential security vulnerability in Anicat, please do not report it through public issues. Instead, please follow these steps:

1.  **Identify the Issue**: Document the steps to reproduce the vulnerability.
2.  **Private Report**: Open a private discussion or contact the developer directly (if contact info is available) to share your findings.
3.  **Acknowledgment**: We will acknowledge your report and work to resolve the issue as quickly as possible.

We believe in responsible disclosure and will work with you to ensure that the vulnerability is fixed before it is publicly announced.

## No Telemetry Guarantee

Anicat is designed as a local-first application. 
- **Zero Tracking**: We do not collect analytics, telemetry, or usage data.
- **Local Storage**: All your data, including login tokens and watch history, is stored exclusively on your local machine.
- **Network Isolation**: The backend service is bound to `127.0.0.1` and cannot be accessed from outside your device.
