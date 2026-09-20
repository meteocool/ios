# meteocool iOS App

This repository contains the full
[meteocool](https://github.com/meteocool/ios) iOS code, including
background location services, notification code and infrastructure.
All components and interaction except the main map view are implemented
natively in Swift (Swift 6 language mode). The map view and all of its data visualization
features and interactions are maintained in the
[meteocool/core](https://github.com/meteocool/core) repository
(ES6/Svelte).

<a href="https://itunes.apple.com/de/app/meteocool-rain-radar/id1438364623"><img src="https://raw.githubusercontent.com/v4lli/meteocool/master/frontend/assets/download-on-appstore.png" style="width: 49%; float: left;" alt="Download on Apple Appstore"></a>

## Building

The Xcode project is generated from [`project.yml`](project.yml) by
[XcodeGen](https://github.com/yonaskolb/XcodeGen) and is not checked in, so
`meteocool.xcodeproj` never has to be edited (or merged) by hand:

```sh
brew install xcodegen
xcodegen generate
```

Everything builds headless, without opening Xcode:

```sh
./scripts/build.sh     # fast unsigned simulator build
./scripts/run.sh       # build, boot a simulator, install and launch
./scripts/test.sh      # UI tests
./scripts/device.sh    # signed build installed on a connected iPhone
./scripts/release.sh   # archive + export a signed App Store .ipa
```

To sign with your own Apple Developer team, copy `Local.xcconfig.example` to
`Local.xcconfig` (gitignored) and set `DEVELOPMENT_TEAM` and `BUNDLE_PREFIX`.
See [CLAUDE.md](CLAUDE.md) for the full layout.

## meteocool ❤️ Open-Source

We welcome all contributions! If you're looking to implement a
feature that is not yet on our
[Issues](https://github.com/meteocool/ios/issues) page, please
create one and let's discuss. 😊

## Credit Where Credit is Due

The meteocool iOS application is maintained by Nina Loser, Florian
Mauracher and Valentin Dornauer.

All code is offered under the AGPL-3.0 license to encourage
collaboration and open-source innovation in meteorology and earth
sciences. Please be aware that we can only accept contributions if
they are also licensed AGPL-3.0.
