# Simplyblock Proxmox integration

## Packaging
```
EMAIL=<mail> gbp dch --git-author --release --new-version <version>-1
git add debian/changelog
git commit -m "Release v<version>"
git tag <version> -m "Version <version>"
dpkg-buildpackage -b --no-sign  # or push to GitHub
```
