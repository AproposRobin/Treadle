# Contributing

Thanks for helping. Contributions arrive as pull requests on https://github.com/AproposRobin/Treadle, and the
maintainer reviews every one.

1. Fork the repository and create a branch for one change.
2. Make the change, build the editor and try it (the build steps are in [README.md](README.md)).
3. Open a pull request and fill in the template: what changed, why, how you tried it.

Report bugs as issues, using the bug report form: what you did, what you expected, what happened, and the version
(`--version` on the editor's command line). Questions and ideas have their own issue forms.
Security problems go through [SECURITY.md](SECURITY.md), not an issue.

## Ground rules

- **One change per pull request.** A fix and a refactor are two pull requests.
- **The graph format is a contract.** Changes to how type files, layouts or projects are written follow
  docs/Format-Stability.md: canonical output stays byte-stable, and a format change comes with its version bump and
  migration.
- **Self tests.** If your change touches something the editor's self tests cover, run them (docs/README.md lists the
  cases) and say in the pull request which ones you ran.
- **UI text** uses the project's own words (Sheet, Outline, Type Settings, Properties, Project Browser, Node menu) in
  labels, menus, messages and docs. Do not use another tool's terms for them.
- **UI changes**: run the editor and check the screens you changed at 1280 and 1920 wide, at 125% scaling, in both
  themes; a screenshot in the pull request helps.
- **Line endings** are LF ([.gitattributes](.gitattributes)). The native host binaries under Native/bin change only
  together with their sha256 in packaging/host-sha256.txt, built by the scripts in Native/.
- **Documentation**: only pages written for users or contributors belong in this repository. Please do not add plans,
  roadmaps or internal notes to a pull request.

## Licence

By contributing you agree that your work is licensed under the Apache License 2.0, like the rest of the project
([LICENSE](LICENSE), [NOTICE](NOTICE)). Third-party code keeps its own licence; add any new dependency's notice to
THIRD_PARTY.md and THIRD_PARTY/ in the same pull request.

Everyone taking part follows the [Code of Conduct](CODE_OF_CONDUCT.md).
