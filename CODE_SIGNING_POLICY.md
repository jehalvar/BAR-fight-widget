# Code signing policy

The SignPath application is pending. SignPath does not currently provide signing for this project. If approved, BAR Fight will use signing through [SignPath.io](https://signpath.io/) with a certificate issued to SignPath Foundation, subject to the [Foundation's terms](https://signpath.org/terms.html).

## Scope and responsibilities

This application covers the public BAR Fight Windows client: the helper, updater, Lua widgets and installer. The separately hosted, private BAR Fight API and replay-analysis backend are outside this signing application and client repository.

[Jens Halvarsson (jehalvar)](https://github.com/jehalvar) is the project's author, reviewer and release-signing approver. Contributions from other authors require maintainer review. Each release-signing request requires Jens's manual approval. Multi-factor authentication is required for repository and SignPath access by all team members.

## Release requirements

Only this project's own artifacts built by its CI from the public client source and reviewed build scripts may be submitted for signing. The intended signing workflow will verify the repository, source revision, build provenance and matching product/version metadata before requesting approval. This document states the required process; it does not claim that SignPath integration or provenance enforcement is already configured.

Upstream binaries must retain their upstream identity and signatures. They must not be submitted as BAR Fight's own code. Inno Setup's runtime is an upstream component of the installer; its notices and license must be preserved.

The updater's RSA-signed manifest is a separate mechanism for authenticating update files. It is not a Windows publisher certificate or evidence of SignPath approval. Neither kind of signature guarantees that Windows SmartScreen will display no warning.

See the [privacy policy](PRIVACY.md) for network transfers and user controls, and [third-party notices](THIRD_PARTY_NOTICES.md) for external components.
