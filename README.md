# apmw

[![test](https://github.com/skerkewitz/apmw/actions/workflows/test.yml/badge.svg)](https://github.com/skerkewitz/apmw/actions/workflows/test.yml)

A wrapper for [Microsoft APM](https://github.com/microsoft/apm) (Agent Package Manager),
modeled on the Gradle wrapper. Add it to a project once, and everyone who works on the
project, including CI, runs the same apm version without installing apm first.

```sh
./apmw install          # Linux, macOS
apmw install            # Windows (apmw.cmd)
```

On the first run, apmw downloads the apm version pinned in `apm/wrapper/apmw.properties`,
checks it against the pinned SHA-256 checksum and stores it in a per-user cache. Every
later run starts the cached apm directly and passes all arguments and the exit code
through.

## Adding apmw to a project

Download one of the two scripts into the project's root folder and run any apm command.

On Linux, macOS or Git Bash:

```sh
curl -fsSLO https://github.com/skerkewitz/apmw/releases/latest/download/apmw
chmod +x apmw
./apmw install
```

On Windows (cmd or PowerShell):

```
curl -fsSLO https://github.com/skerkewitz/apmw/releases/latest/download/apmw.cmd
apmw.cmd install
```

On the first run in a project, apmw sets up the rest, much like `gradle wrapper`:

- It pins the latest apm release and its checksums in `apm/wrapper/apmw.properties`.
- It adds the other script (`apmw.cmd` or `apmw`) from the same apmw release.

If the second step fails, for example offline, apmw only warns. Run `--apmw-upgrade`
later to add the missing script. If you delete one of the scripts on purpose, apmw
doesn't add it back.

Commit these files:

```
apmw
apmw.cmd
apm/wrapper/apmw.properties
```

Also add these lines to the project's `.gitattributes`. Without them, Git on Windows can
change the line endings and break the scripts:

```
apmw      text eol=lf
apmw.cmd  text eol=crlf
```

If you set up the project on Windows, Git doesn't know that `apmw` is executable. Mark it
once, as you would for `gradlew`:

```sh
git update-index --chmod=+x apmw
```

## Commands

Arguments that start with `--apmw-` are handled by the wrapper. Everything else is passed
to apm.

| Command | What it does |
|---|---|
| `apmw --apmw-help` | Show help. |
| `apmw --apmw-version` | Show the wrapper version and the apm version in use. |
| `apmw --apmw-upgrade-apm [VERSION]` | Pin another apm version (default: latest) and write its checksums. |
| `apmw --apmw-upgrade [VERSION]` | Replace `apmw` and `apmw.cmd` with another release (default: latest). |

Both upgrade commands only change files in your project. Review the diff and commit it.
A normal apmw run never changes project files.

`apm self-update` is blocked under apmw, because it would bypass the pinned version. Use
`--apmw-upgrade-apm` instead.

## Configuration

`apm/wrapper/apmw.properties`:

| Key | Meaning |
|---|---|
| `apmVersion` | apm release tag to run, e.g. `v0.35.0` |
| `apmSha256.<platform>` | Expected SHA-256 of each platform's release archive |
| `apmReleasesUrl` | Where apm releases come from (default `https://github.com/microsoft/apm/releases`) |
| `wrapperVersion` | apmw release in use (informational) |
| `wrapperReleasesUrl` | Where apmw releases come from (default `https://github.com/skerkewitz/apmw/releases`) |

Downloads use `<releasesUrl>/download/<tag>/<file>`. Finding the latest version uses the
redirect from `<releasesUrl>/latest`. A mirror with the same layout works. On a mirror
without the `/latest` redirect, pass versions explicitly.

Environment variables override the properties for a single run or in CI:

| Variable | Overrides |
|---|---|
| `APMW_HOME` | Cache directory: `~/.apmw` (Linux, macOS), `%LOCALAPPDATA%\apmw` (Windows) |
| `APMW_APM_VERSION` | `apmVersion`. Its download is checked against the release's published `.sha256` file, unless it matches the pinned version. |
| `APMW_APM_RELEASES_URL` | `apmReleasesUrl` |
| `APMW_WRAPPER_RELEASES_URL` | `wrapperReleasesUrl` |

## Behavior

- **Cache:** `<APMW_HOME>/dists/<version>/<platform>/`. It's shared by all projects on the
  machine. You can delete it at any time; it's downloaded again when needed.
- **Offline:** if the pinned version is cached, apmw runs it without touching the
  network. If it isn't cached and the download fails, apmw stops with an error. It never
  falls back to a different cached version.
- **Integrity:** the download must match the pinned SHA-256 before it's unpacked. apmw
  also runs `apm --version` on the new copy before moving it into the cache. A failed
  install leaves nothing behind.
- **Platforms:** Linux and macOS on x86_64 and arm64, Windows on x86_64. Windows on ARM
  runs the x86_64 build through emulation. On Linux, the official apm binary needs a
  reasonably recent glibc.
- **Requirements:** `curl`, `tar` and `sha256sum` or `shasum` on Linux and macOS; Windows
  PowerShell 5.1 (included with Windows 10 and 11) on Windows.
- **Git Bash:** `./apmw` also works in Git Bash, MSYS2 and Cygwin on Windows. It uses the
  same cache as `apmw.cmd` (`%LOCALAPPDATA%\apmw`), so apm is downloaded only once per
  machine.

## Tests

[tests/test.sh](tests/test.sh) tests both scripts end to end: first run, cache, offline
behavior, checksums, argument and exit-code passthrough, and self-upgrade. It runs on
every push on GitHub Actions:

| Runner | Platform |
|---|---|
| `ubuntu-latest`, `ubuntu-24.04-arm` | Linux x86_64 and arm64 |
| `macos-latest`, `macos-15-intel` | macOS arm64 and x86_64 |
| `windows-latest`, `windows-11-arm` | Windows x64 and ARM (`./apmw` in Git Bash and `apmw.cmd`) |

Run it locally with `tests/test.sh` (on Windows from Git Bash). It needs `curl`,
`python3` and access to github.com.

## Releasing apmw

Push a tag such as `v0.1.0`. The workflow in `.github/workflows/release.yml` runs the
tests on all platforms first. If they pass, it publishes `apmw`, `apmw.cmd` and
`apmw.sha256` as release assets, which is what `--apmw-upgrade` downloads.
