# Changelog

## 0.7.0 - 2026-11-02

### Changes

- Initial import of the DSS Docker bootstrap
- Guard DSS upgrades, pin the base image, add a healthcheck and tests
- Name images per Compose project; rewrite the smoke test for readability
- One Compose file per instance; no upgrade handling
- Move the image files to image/; align the shell scripts
- Prepare the repository for publication
- Shorten the README and add docs/
- Make the host port configurable with DSS_HOST_PORT
- Rework the instances around DSS versions
- Generate release notes with git-cliff on version tags
- Maintain CHANGELOG.md in the release steps
