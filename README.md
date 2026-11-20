# ZooDirector

English | [简体中文](README.zh-CN.md)

A native macOS ZooKeeper client with a Finder-style interface, built with Swift, SwiftUI, and AppKit. No JVM or WebView dependencies.

![ZooDirector screenshot](docs/screenshot.png)

## Features

- Multiple connections, connection testing, digest authentication, and SSH tunnels, with independent browsing and editing state for each connection.
- Tree browsing without pagination, path navigation, favorites, and column sorting.
- Node data, creation and modification times, child counts, and ephemeral node indicators.
- Search the current directory or include subdirectories; current-directory results remain expandable and collapsible.
- Text editing, persistent and ephemeral node creation, multiple selection, and confirmation for recursive deletion.
- Live Watch updates, with one-time watches for ZooKeeper 3.4 / 3.5 and persistent watches for 3.6+.
- English and Simplified Chinese interfaces, selectable in Settings.

## Build and Run

Requires macOS 14+ and Xcode or a Swift toolchain with the macOS SDK. Verified on Apple Silicon with Swift 6.4.2.

```sh
git clone git@github.com:ssfyn/zoo-director.git
cd zoo-director
./scripts/build-app.sh
open ".build/ZooDirector.app"
```

Use `./scripts/build-app.sh debug` for a development build, or open `Package.swift` in Xcode. An optional second argument selects the architecture, such as `./scripts/build-app.sh release x86_64` or `./scripts/build-app.sh release universal`; explicit architecture builds go to `.build/apps/ARCH/ZooDirector.app` without replacing the development app.

Builds update the same app bundle. Restart the app to load changes. The build produces an ad hoc signed app for the local architecture; it is not notarized. Bundle identifier: `fan.yanan.zoodirector`.

## GitHub Actions

Publishing a Release such as `v1.0.0` builds, signs, notarizes, and uploads ARM and Intel DMGs. Configure the six repository Secrets described in [the release guide](docs/releases.md) (in Chinese) first. For immutable releases, run the workflow manually for an existing tag, then publish the completed draft.

Local builds display `dev` in About. Release builds use the tag version and an Actions build number. Distribution channels are explicit; App Store metadata is reserved, while store signing and uploading remain a future step.

## Signed and Notarized Releases

Use `scripts/release-app.sh` with an active Apple Developer Program membership, a Developer ID Application certificate and its private key in your local Keychain, and Xcode tools including `notarytool` and `stapler`. Signing and notarization require network access.

Store notarization credentials once, following the prompts for your Apple account, Team ID, and app-specific password. Leave the API private key path empty when using account authentication:

```sh
xcrun notarytool store-credentials "zoodirector-notary"
security find-identity -v -p codesigning
```

Copy your Developer ID Application identity's full name or SHA-1 from the second command into a local `scripts/.env` to avoid signing with another team's certificate:

```sh
SIGNING_IDENTITY="Developer ID Application: Your Name (TEAMID)"
NOTARY_PROFILE="zoodirector-notary"
```

The build and release shell scripts load this file locally when present, using shell syntax, and exports its variables to child processes. Assignments in the file override existing environment variables. Quote values containing spaces. Git ignores this file; create it locally after cloning. Without it, scripts still accept environment variables.

Then run:

```sh
APP_VERSION=1.0.0 ./scripts/release-app.sh
```

The script checks the identity and credentials, then produces three release artifacts by default:

- `dist/ZooDirector-VERSION-arm64.dmg`: Apple Silicon.
- `dist/ZooDirector-VERSION-x86_64.dmg`: Intel.
- `dist/ZooDirector-VERSION-universal.app`: a Universal app containing both architectures.

Each app is checked for its target architecture, signed with Hardened Runtime, notarized, stapled, and validated. The Universal app merges the two main executables with `lipo`, requires identical resources, and is signed and notarized after merging. Each DMG contains the stapled app and an `/Applications` shortcut; the DMG itself is also signed, notarized, stapled, and validated. ZIP files are used only for temporary app notarization uploads inside working directories. The default workflow submits five notarization requests.

All artifacts require macOS 14+. Each rebuild needs signing and notarization again. Cross-compilation does not run the target binary; test the Intel build and the Universal app's Intel slice on an Intel Mac.

To generate only one artifact, run `APP_VERSION=1.0.0 ./scripts/release-app.sh arm64`, `APP_VERSION=1.0.0 ./scripts/release-app.sh x86_64`, or `APP_VERSION=1.0.0 ./scripts/release-app.sh universal`. Each artifact has its own working directory and notarization records. A failure stops subsequent steps; previously published artifacts are retained.

Override the default Keychain profile with `NOTARY_PROFILE`. Run `./scripts/release-app.sh --help` for usage. Notarization can take time. Failures retain submission responses, working files, and available diagnostic logs in `dist/.release.*`. Apple may continue processing an uploaded submission after an interrupted wait; query it with `xcrun notarytool info SUBMISSION_ID --keychain-profile zoodirector-notary`. Successful releases replace existing artifacts of the same version and architecture; failed validation preserves existing artifacts. ZIPs from previous workflows are not automatically removed.

`dist/` is ignored by Git. The script references a Keychain profile without embedding credentials. Never commit app-specific passwords, `.p8` keys, or `.p12` files containing private keys. See [Apple's notarization workflow](https://developer.apple.com/documentation/security/customizing-the-notarization-workflow).

## Usage

Add a connection using `host:port`, then click **Connect** to browse. Enter an absolute path in the address bar, double-click a node to enter it, or double-click `..` to go up one level.

Click `+` to create a node, or select a node to edit its data in the inspector. Use `⌘`-click or `Shift`-click to select multiple nodes, then click the trash button to delete them. Nonempty nodes require **Delete all child nodes as well**. With digest enabled, new nodes are accessible only to the current authenticated identity; otherwise, they use the open `world:anyone` ACL. Batch deletion stops at the first failure, and completed deletions are not rolled back.

digest usernames are stored in connection settings; passwords are stored in macOS Keychain. Leave the password unchanged when editing to keep the saved password. Connection testing confirms that the identity was submitted; actual access depends on each node's ACL. digest does not encrypt traffic and can be combined with an SSH tunnel.

SSH supports key authentication only. The ZooKeeper address must be reachable from the SSH server. Connect from a terminal and verify the SSH host fingerprint before first use; add encrypted private keys to ssh-agent beforehand.

Common shortcuts: `⌘N` add a connection, `⇧⌘G` focus the path bar, `⌘R` refresh, `⇧⌘N` create a node, `⌘⌫` delete selected nodes, `⌘S` save, and `⌘,` open Settings.

## Limitations

- SASL, TLS, chroot, cluster failover, automatic reconnection, and ACL editing are not supported.
- Search matches node names only. Recursive searches have scan and result limits, with a notice when a limit is reached.
- Non-UTF-8 data and content larger than 256 KiB have read-only previews. Writes are limited to 1,000,000 bytes.
- Saves check the data version, and writes are not retried automatically. Refresh to confirm the result after a network error.
- All names in the current directory are loaded, while metadata is fetched on demand. Very large directories still consume memory accordingly.

## Tests

UI strings use English source text as localization keys, for example `L10n.text("Preferences")`. The matching JSON catalogs are in `Sources/ZooDirector/Resources/Localization/`: `en.json` maps each key to itself and `zh-Hans.json` provides the Chinese translation. Dynamic status and error messages also use English source templates so they can be translated when displayed. Language names in the picker retain their native spelling.

```sh
swift test --disable-sandbox
```

Tests requiring a real server are skipped unless configured. Setting `ZOODIRECTOR_TEST_ENDPOINT` enables actual read/write tests: use an isolated instance with a writable `/zoodirector-test` node created in advance.

See [docs/validation.md](docs/validation.md) for validation records (in Chinese).
