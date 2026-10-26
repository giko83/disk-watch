# Portable, no-install CLI (first step of issue #18)

Disk Watch can run directly from a checkout or extracted source tree without installing a systemd service or writing to `/usr/local/sbin` or `/etc`. This is a **one-shot kernel-journal check**, not a cross-platform journal backend. A local portable archive can now be built from the repository; a published release is not yet available.

## Prerequisites

- Linux with Bash, `journalctl` and a readable **systemd kernel journal** for `init` and `check`.
- Basic utilities: `mkdir`, `chmod`, `flock`, `grep`, `sed`, `tail`, `cut`, `wc`, `mv` and `hostname`.
- Choose a notification transport: working `sendmail` for `mail`, or `curl` for `telegram`.
- **No root, systemd timer, Git, database, Python or Node.js is required at runtime** if the invoking user can read the kernel journal and write to its chosen state directory. Many Linux installations restrict journal access to privileged users; check local policy rather than broadly weakening permissions.

If `journalctl` is missing or its kernel journal is not readable, `init`/`check` fail with a diagnostic. Portable mode does **not** invent kernel events or silently substitute a different backend.

## Create a portable archive (optional)

From a checkout, run the offline builder:

```sh
bash scripts/build-portable.sh
tar -xzf dist/disk-watch-portable.tar.gz
cd disk-watch-portable
bash ./disk-watch.sh --help
```

The builder accepts an optional output path, including paths with spaces: `bash scripts/build-portable.sh "/tmp/disk watch.tar.gz"`. It requires Bash, `tar`, `cp`, `mkdir`, `mktemp` and `chmod` but **not Git, root, a database, network or systemd** at build time. It packages an allowlisted set of public files: the CLI, sample config, README, license, changelog and documentation. It deliberately excludes the real config, tokens, cursor, state, Git metadata and systemd units. The resulting archive is a source bundle, not a compiled executable or a tagged release. Extract it into a directory you control.

Run `init` and `check` from the extracted directory with your private config and state directory **outside** the archive, as described below. Runtime kernel monitoring still needs an accessible `journalctl` and a chosen notification transport. The builder does not install or update services.

## Run once, without installation

Save a trusted config outside the checkout, for example `$HOME/.config/disk-watch/config`, and restrict it to the invoking user (`chmod 600`). The config is **sourced as Bash**, so only use a file you control. Start from `disk-watch.conf.example`; for example:

```bash
HOST_LABEL=portable-linux
TRANSPORT=mail
# Or use TRANSPORT=telegram and set TG_BOT_TOKEN / TG_CHAT_ID privately.
```

From the source tree, initialize the cursor and perform a check:

```sh
bash ./disk-watch.sh --help
bash ./disk-watch.sh --config "$HOME/.config/disk-watch/config" --state-dir "$HOME/.local/state/disk-watch" init
bash ./disk-watch.sh --config "$HOME/.config/disk-watch/config" --state-dir "$HOME/.local/state/disk-watch" check
```

`init` deliberately starts monitoring **after** the latest existing kernel event; historical events are not replayed. It preserves an existing cursor. `check` is an alias for the existing `scan` command and advances the cursor only after notification delivery succeeds. The default command remains `scan` for backward compatibility. State and lock files are created under the selected directory. New state directories and files use private permissions; existing directories are **not chmodded** by the CLI, so choose a directory with appropriate access controls.

Options can appear before or after the command. The CLI takes precedence over `DISK_WATCH_CONFIG` and `DISK_WATCH_STATE_DIR` environment variables; the state directory also falls back to `STATE_DIR` inside the config, then `/var/lib/disk-watch`. Paths containing spaces are supported when quoted.

## Schedule externally (optional)

On Debian, Ubuntu and Proxmox, the existing systemd timer installation remains supported. For a no-install workflow, run the `check` command from an existing scheduler such as cron, **only after** manually initializing the cursor. Example user crontab entry (replace paths with absolute paths appropriate to the host):

```cron
* * * * * /bin/bash /home/user/disk-watch/disk-watch.sh --config /home/user/.config/disk-watch/config --state-dir /home/user/.local/state/disk-watch check
```

Use an account with journal access and a writable state directory. Cron's environment can differ from an interactive shell; specify absolute paths and configure the chosen notification transport. For paths containing spaces, quote them appropriately. The built-in `flock` prevents overlapping scans of the same state directory.

## Limits and safe behavior

- No SMART test is started by `check`; SMART remains separately integrated through `smartd`.
- The kernel journal and persistent cursor are still required; unsupported Linux distributions without journald need a future backend.
- Journal read errors cause a failure and leave the cursor unchanged. **Journal rotation or an expired cursor can still create a gap that the current monitor does not always detect**; review the kernel journal and reinitialize the cursor only deliberately.
- The portable workflow does not update installed production services. Keep configs and tokens out of Git and avoid using a world-readable state directory.
- Formal release distribution, additional platform compatibility tests and any non-journald backend remain tracked under [issue #18](https://github.com/giko83/disk-watch/issues/18).
