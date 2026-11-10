# Contributing to Upkeep

Thanks for taking a look. Upkeep is a small app maintained in spare time, so the best
contributions are focused ones.

- **Bugs:** open an issue with your macOS version, Mac model (Apple Silicon or Intel), the app
  version (Settings → About), and steps to reproduce.
- **Features:** open an issue first so we can agree on the shape before you write code.
- **Pull requests:** keep them small and on one topic. Run `swift build` before pushing, and
  check the change in the installed app (`./scripts/install.sh`), since most bugs in menu bar apps
  only show up there.

## Working on the UI toolkit

Shared UI lives in [MacUtilityKit](https://github.com/georgecristea/MacUtilityKit). To change it and
this app together, clone it next to this repo and run:

```sh
swift package edit MacUtilityKit --path ../MacUtilityKit
```

`swift package unedit MacUtilityKit` switches back to the released version.

## Licensing

By contributing you agree that your contribution is licensed under this project's
[MIT License](LICENSE).
