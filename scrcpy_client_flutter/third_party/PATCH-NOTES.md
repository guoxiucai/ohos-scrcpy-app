# third_party/xterm

Vendored from `xterm` 4.0.0 (pub.dev) with one local patch:

- `lib/src/ui/shortcut/shortcuts.dart`: added `default:` branch to the
  `switch (defaultTargetPlatform)` so it compiles against OpenHarmony's
  Flutter fork (`Flutter 3.41.10-ohos-1.0.0`), which adds an extra
  `TargetPlatform.ohos` enum value that exhaustive switches must handle.

Why vendor instead of `dependency_overrides`:
- pub-cache patches are non-portable across machines and CI.
- A fork branch on GitHub would also work, but vendoring keeps the patch
  inspectable in this repo.

To re-sync with upstream xterm later: copy the new release into this dir
and re-apply the `default:` branch to `shortcuts.dart`.
