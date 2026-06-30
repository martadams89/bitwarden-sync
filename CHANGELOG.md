# Changelog

## [1.1.0](https://github.com/martadams89/bitwarden-sync/compare/v1.0.0...v1.1.0) (2026-06-30)

### Features

- enhance release workflow with auto-merge capability and token handling ([8f18abc](https://github.com/martadams89/bitwarden-sync/commit/8f18abc67c7d7ae821e49a824d6b243f0d4a4532))

## 1.0.0 (2026-06-30)

### Features

- add environment variables for device identifier and name in CLI compatibility test ([5dc0824](https://github.com/martadams89/bitwarden-sync/commit/5dc0824c56d17d2644cac6e7d6808904f166960a))
- add GitHub workflows for Docker image builds and releases ([cbbd19f](https://github.com/martadams89/bitwarden-sync/commit/cbbd19f476b7dcca6eea81e021ee4617959277ad))
- add manual run and monitoring features with healthcheck support ([aa5d87a](https://github.com/martadams89/bitwarden-sync/commit/aa5d87a1262b710b9d04af4e8c8e71e04fa831db))
- add NODE_OPTIONS to suppress deprecation warnings in CLI compatibility tests ([fef1d66](https://github.com/martadams89/bitwarden-sync/commit/fef1d664c3af046a1ef1efbd08667c72407f0c6b))
- enable HTTPS support for Vaultwarden in CLI compatibility tests ([606f4f1](https://github.com/martadams89/bitwarden-sync/commit/606f4f1a7aae15fe3c471fa35c88b80f72f963c3))
- enhance Bitwarden CLI handling with version reconciliation and improved source login resilience ([adfee1e](https://github.com/martadams89/bitwarden-sync/commit/adfee1eda83d018ee9fd818b5ba31b5ebb826fa8))
- enhance Bitwarden sync functionality with CLI version management and resilience improvements ([f2d58a9](https://github.com/martadams89/bitwarden-sync/commit/f2d58a98d82bde93e820023b29e6c3adf316066e))
- enhance DNS configuration in run.sh for improved container networking ([b7360b8](https://github.com/martadams89/bitwarden-sync/commit/b7360b82cb2d10308e3cce5224fd289d3b7db835))
- enhance DNS resolution in CLI compatibility tests for external cloud access ([05e78e4](https://github.com/martadams89/bitwarden-sync/commit/05e78e4736cfcc41414511e5a788769e4dc70990))
- enhance DNS resolution in run.sh for improved container networking ([64fc3b5](https://github.com/martadams89/bitwarden-sync/commit/64fc3b54bd7f45ba4c584905336210b0750c6cb8))
- enhance Docker script to support custom API and identity URLs ([09da395](https://github.com/martadams89/bitwarden-sync/commit/09da39566eb2d308f8021768f33b59f7fa0337c9))
- implement caching for Bitwarden CLI state to prevent "new device" emails ([15c1886](https://github.com/martadams89/bitwarden-sync/commit/15c18869eab29d9483a6363796496468fcce1f8c))
- improve host resolution handling in run.sh with error logging ([6334932](https://github.com/martadams89/bitwarden-sync/commit/6334932fa2835f6f9e3372d0df26d20539c5cd4e))
- improve networking in run.sh for enhanced container DNS resolution ([c0727d8](https://github.com/martadams89/bitwarden-sync/commit/c0727d821066767737b6e58394332fc771981865))
- remove commit-linting workflow to streamline CI processes ([21b2a7d](https://github.com/martadams89/bitwarden-sync/commit/21b2a7d9c2c199347faa6a96526b9eeb9c84e54f))
- sanitize destination URL in run.sh to remove trailing whitespace and invalid characters ([12690e7](https://github.com/martadams89/bitwarden-sync/commit/12690e7968b1d678eaf5ec263d3590fc4730c611))
- support encrypted passwords in Docker setup ([f7dc442](https://github.com/martadams89/bitwarden-sync/commit/f7dc442aaa5477022a49d65b47a76f5ed90f7290))
- update CLI compatibility test workflow and renovate configuration for improved auto-merge handling ([07ea678](https://github.com/martadams89/bitwarden-sync/commit/07ea678e567fdb291c0dcfc47d258f8521599d00))
- update docker-compose and run.sh for improved network accessibility in CLI compatibility tests ([f6a796c](https://github.com/martadams89/bitwarden-sync/commit/f6a796c9d97e6829155ee373d30d3a3688b0408a))
- update docker-compose and run.sh to use a user-defined network for CLI compatibility tests ([f5bd71e](https://github.com/martadams89/bitwarden-sync/commit/f5bd71e55835d6f1764ab7a7994ac59b385c2de1))

### Bug Fixes

- CLI 2026.x compat — use REST API for vault clearing, PTY for import ([863ef49](https://github.com/martadams89/bitwarden-sync/commit/863ef4969841df66663b9495ef83eaae10d41054))
- correct Bitwarden CLI installation paths and wrapper script execution ([06e5f57](https://github.com/martadams89/bitwarden-sync/commit/06e5f570eb4d1497940863ef58bfafb998aebaae))
- improve error handling during Bitwarden login and vault unlocking ([0d47faa](https://github.com/martadams89/bitwarden-sync/commit/0d47faac4bc93cd39a86879a2631120fd8dcdc78))
- improve login error handling for Bitwarden servers ([934cc60](https://github.com/martadams89/bitwarden-sync/commit/934cc608f2d4b644c6d6f54c24041d2a1cc244d5))
- persist bitwarden cli client identity in docker runs ([6b8b92a](https://github.com/martadams89/bitwarden-sync/commit/6b8b92a5635f2530c4d0f49cc65722f7cdce1e4c))
- streamline installation of Bitwarden CLI with separate wrapper scripts ([8bf5aae](https://github.com/martadams89/bitwarden-sync/commit/8bf5aaedbd32af1bffbeec572a9e8017b228f379))
- update Bitwarden CLI installation paths for compatibility ([2ba8b0e](https://github.com/martadams89/bitwarden-sync/commit/2ba8b0e8730122c1a2892328ae170f6432562431))
- update Bitwarden CLI usage for compatibility with Vaultwarden and Bitwarden Cloud ([7d09f85](https://github.com/martadams89/bitwarden-sync/commit/7d09f8543254d272e05068cd7bd4debcea3880d2))
- update login process to use unlock for Bitwarden vaults ([1c96af9](https://github.com/martadams89/bitwarden-sync/commit/1c96af95cbd0ae611771e608606048273274eb4e))
- update vault unlocking process to remove client ID and secret exports ([bc9c5a1](https://github.com/martadams89/bitwarden-sync/commit/bc9c5a1c8463d98afdb8fbdba9c4adf30c1dce19))

### Miscellaneous Chores

- release 1.0.0 ([fc60df3](https://github.com/martadams89/bitwarden-sync/commit/fc60df3e29aa2e1ca03f17d58c6885d2f21a48f8))

## Changelog

All notable changes to this project are documented in this file.

It is maintained automatically by [release-please](https://github.com/googleapis/release-please)
from [Conventional Commit](https://www.conventionalcommits.org/) messages — entries
below this line are added when a release PR is merged.
