# Platform support

`setup.sh` reads `ID` from `/etc/os-release` and loads `lib/platform/<ID>.sh`. Only `ubuntu.sh`
exists today; it is used on WSL2 and on AWS EC2.

To add a distro, create `lib/platform/<ID>.sh` defining:

| Function | Contract |
|---|---|
| `platform_missing_packages` | Print one name per line for each required tool not installed: `git`, `curl`, CA certificates, `python3`, and `gh` (GitHub CLI). Print nothing when all are present. |
| `platform_install_packages NAME...` | Install the names printed above, using `sudo` as needed. |
| `platform_hostname_check NAME` | Exit 0 if the hostname is set to persist as `NAME` and resolves (it may still need a restart); print what's missing with `info`. |
| `platform_hostname_apply NAME` | Make it so, using `sudo`. Don't restart anything. |

Every platform must run **systemd** as PID 1 with a working user manager (`systemctl --user`).
That is a hard requirement: Remote Control servers and the refresh timer are systemd user units.

Please include a test (see `tests/`) and note in the PR which distro version you tested on.
