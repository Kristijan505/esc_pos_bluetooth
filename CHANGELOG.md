## [0.5.0]

- Breaking: bump minimum Dart to `3.11` and Flutter to `3.41.0`.
- Pin `esc_pos_utils` git dependency to commit `deee20c61573ca97bd5b041457832a4981b10cd0`.
- Pin `flutter_bluetooth_basic` git dependency to commit `05e0127af523a1613403100103f3804ae0ea0783`.
- Align with Android plugin toolchain upgrades shipped in pinned `flutter_bluetooth_basic` commit
  (`AGP 8.13.2`, `Gradle 8.13`, `compileSdk/targetSdk 36`, `JDK 21`).
- Add Android 12+ Bluetooth runtime permissions (`BLUETOOTH_SCAN`, `BLUETOOTH_CONNECT`) with
  legacy location permission flow for Android 11 and below in pinned plugin commit.
- Align iOS plugin podspec metadata and deployment target (`13.0`) in pinned plugin commit.
- Fix Android smoke build compatibility by removing unsupported `JavaCompile.options.release`
  flag in pinned plugin commit.

## [0.4.1]

- Bump flutter_bluetooth_basic to ^0.1.7

## [0.4.0]

- Bump esc_pos_utils to ^1.1.0. Using Generator instead of Ticket

## [0.3.0]

- Null-Safety

## [0.2.8]

- Bump esc_pos_utils

## [0.2.7]

- Updated flutter_bluetooth_basic

## [0.2.6]

- Updated flutter_bluetooth_basic

## [0.2.5]

- Split data into chunks

## [0.2.4]

- `startScan` timeout bug fixed.
- Updated `esc_pos_utils` package version to `0.3.4`.

## [0.2.3]

- Updated `esc_pos_utils` package version to `0.3.3`.

## [0.2.2]

- Updated `esc_pos_utils` package version to `0.3.2`.

## [0.2.1]

- Updated `esc_pos_utils` package version to `0.3.1` (Open Cash Drawer).

## [0.2.0]

- Updated `esc_pos_utils` package version to `0.3.0` (Image and Barcode alignment).

## [0.1.1]

- Updated `esc_pos_utils`, `flutter_bluetooth_basic` package versions

## [0.1.0]

- Android and iOS Bluetooth printing support
