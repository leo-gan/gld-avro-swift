# Publishing

Swift Package Manager installs this package from the Git tag. The public index is the [Swift Package Index](https://swiftpackageindex.com/leo-gan/gld-avro-swift). There is no public upload registry that holds the community's packages the way PyPI does. A package registry that speaks the Swift package-registry API is optional.

The package name is `gld-avro-swift`. The library product is `Avro`. The version in `VERSION` is `0.2.0`. Release tags match the Mojo libraries and have no `v` prefix: `0.2.0`. Swift Package Manager accepts that tag for `from: "0.2.0"`.

## Register once

The index accepts a package after at least one semantic-version tag exists, so create the `0.2.0` GitHub Release before this step.

1. Open [swiftpackageindex.com/add-a-package](https://swiftpackageindex.com/add-a-package).
2. Choose Add Package(s). GitHub opens an issue on [SwiftPackageIndex/PackageList](https://github.com/SwiftPackageIndex/PackageList/issues/new/choose).
3. Put this URL in the package list, including `https://` and `.git`:

    `https://github.com/leo-gan/gld-avro-swift.git`

The index builds the tag and adds the package page. No token is stored in this repository for that step.

To publish into a Swift package registry you run yourself, add repository secrets:

| Name | Value |
| --- | --- |
| `SWIFT_REGISTRY_URL` | Registry base URL, for example `https://example.com/swift`. |
| `SWIFT_REGISTRY_TOKEN` | Token accepted by `swift package-registry login`. |
| `SWIFT_PACKAGE_ID` | Optional. The default is `leo-gan.gld-avro-swift`. |

Leave those secrets unset to publish only the git tag. The release workflow still runs the tests, builds a source zip with `swift package archive-source`, and attaches that zip to the GitHub Release.

## Publish a version

Merge `.github/workflows/publish.yml` to `main` before creating the release.

```bash
git checkout main
git pull
git tag 0.2.0
git push origin 0.2.0
gh release create 0.2.0 --target main --title 0.2.0 --generate-notes
```

Check the archive without uploading:

```bash
bash scripts/publish.sh --dry-run
```

## Install

```swift
.package(url: "https://github.com/leo-gan/gld-avro-swift", from: "0.2.0"),
```

Depend on the library product `Avro`.
