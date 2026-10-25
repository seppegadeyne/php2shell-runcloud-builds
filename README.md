# php2shell-runcloud-builds

Unofficial, patched builds of PHP 5.6 to 8.1 for RunCloud servers on Ubuntu 16.04, 18.04,
20.04, 22.04 and 24.04, with the fix for PHP2Shell (CVE-2026-109618 and CVE-2026-109619).
Plus the scripts, patches and configure commands to build them yourself, and a generic mode
that patches a self-compiled PHP on servers without RunCloud (see below).

The PHP project only released fixes for 8.2 and newer (8.2.35, 8.3.36, 8.4.27, 8.5.12), and
RunCloud only ships those, on its supported Ubuntu releases. The 18.04 repository stopped at
8.3.17 and 8.2.27, and the 16.04 repository tops out at PHP 8.0. This repository fills that
gap for our own servers, and now for anyone in the same spot.

Background and the full story: [Patching PHP 5.6 to 8.1 for PHP2Shell on old Ubuntu servers by
rebuilding RunCloud's PHP](https://dev.to/seppegadeyne/patching-php-56-to-81-for-php2shell-on-old-ubuntu-servers-by-rebuilding-runclouds-php-1bl7).

> **Not affiliated with RunCloud or the PHP project.** These builds are provided as is, without
> warranty or support. They are a stopgap for one vulnerability, not a maintained distribution:
> held packages get no updates from RunCloud anymore, so the next PHP bug is again your job.
> Read the scripts before you run them as root, and test on one server first.

## What is available

Release [`v2026.10.21`](https://github.com/seppegadeyne/php2shell-runcloud-builds/releases/tag/v2026.10.21)
has 25 tarballs and a `SHA256SUMS` file:

| Ubuntu | Codename | Patched PHP | Unchanged official release |
| --- | --- | --- | --- |
| 16.04 | xenial | 5.6.40, 7.0.33, 7.1.33, 7.2.34, 7.3.33, 7.4.33, 8.0.30 | |
| 18.04 | bionic | 7.0.33, 7.1.33, 7.2.34, 7.3.33, 7.4.33, 8.0.30, 8.1.34 | 8.2.35, 8.3.36 |
| 20.04 | focal | 7.2.34, 7.3.33, 7.4.33, 8.0.30, 8.1.34 | |
| 22.04 | jammy | 7.4.33, 8.0.30, 8.1.34 | |
| 24.04 | noble | 8.1.34 | |

The 18.04 builds of 8.2.35 and 8.3.36 are the official php.net releases, built with RunCloud's
flags, because RunCloud no longer builds anything for 18.04. One of them is named
`php82rc-8.2.35-php2shell-bionic.tar.gz` for historical reasons; it has no extra patch.

For 8.2 and newer on 20.04, 22.04 and 24.04, use RunCloud's own packages:
`apt-get update && apt-get install --only-upgrade php82rc php83rc php84rc php85rc`.

A patched build reports the same version as before (`PHP 7.4.33`). `php -v` proves nothing;
compare file hashes instead (see below).

## How the builds are made

- Built inside the matching official `ubuntu-base` root filesystem, as a rootless chroot
  (user namespace, no sudo, no Docker), so every binary links the same glibc, OpenSSL and ICU
  as the server.
- Configured with RunCloud's own configure command, copied from `php -i` on the server
  (`configure/`).
- Linked against RunCloud's own `libargon2` (and on 22.04 for 7.4/8.0 its `libssl1-rc`,
  OpenSSL 1.1.1b), downloaded from `release.runcloud.io` and checked against the SHA-256 in
  RunCloud's package index.
- Source: the php.net tarball plus one patch from `patches/` (origin and authors in
  `patches/README.md`). The patch does not change `ZEND_MODULE_API_NO`, so the extensions
  already on the server keep loading.

## Install a release tarball

On the server, as root. Example for PHP 7.4 on Ubuntu 20.04:

```bash
mkdir -p /root/php2shell && cd /root/php2shell
BASE=https://github.com/seppegadeyne/php2shell-runcloud-builds/releases/download/v2026.10.21
curl -fLO $BASE/php74rc-7.4.33-php2shell-focal.tar.gz
curl -fLO $BASE/SHA256SUMS
curl -fLO https://raw.githubusercontent.com/seppegadeyne/php2shell-runcloud-builds/main/deploy-core.sh
sha256sum -c --ignore-missing SHA256SUMS

bash deploy-core.sh 74 php74rc-7.4.33-php2shell-focal.tar.gz
```

Pick the tarball that matches **both** the PHP version and the server's Ubuntu release
(`lsb_release -cs`). A build for another release will not run correctly.

What `deploy-core.sh` does:

1. Copies the original `bin/php`, `sbin/php-fpm` and six core extensions once to
   `/root/phpXXrc-orig-before-php2shell/`.
2. Starts the new binary with the server's real `php.ini` and aborts on any startup warning.
3. Replaces only `bin/php`, `sbin/php-fpm` and the shared core extensions (`mysqlnd`, `pdo`,
   `xml`, `xmlreader`, `xmlwriter`, `readline`) by rename. RunCloud's other extensions and all
   `conf.d` files stay as they are.
4. Puts the package on hold (`apt-mark hold phpXXrc`) so RunCloud's agent does not reinstall
   the unpatched build.
5. Tests the FPM config and restarts the service if it was running; rolls back on failure.
   A version without pools gets the new binaries but its service is not started.

Rollback:

```bash
bash deploy-core.sh 74 php74rc-7.4.33-php2shell-focal.tar.gz rollback
```

The hold is the trade-off: that version gets no RunCloud updates at all until you
`apt-mark unhold` it.

## Check that it worked

```bash
# the running FPM master uses the new file
sha256sum /RunCloud/Packages/php74rc/sbin/php-fpm \
  /proc/$(systemctl show -p MainPID --value php74rc-fpm)/exe
# compare with the file in the tarball
tar -xzf php74rc-7.4.33-php2shell-focal.tar.gz -O RunCloud/Packages/php74rc/sbin/php-fpm | sha256sum

# out-of-memory now ends the process (exit 1) instead of running shutdown functions
/RunCloud/Packages/php74rc/bin/php -d memory_limit=8M \
  -r 'register_shutdown_function(function(){echo "shutdown-ran\n";}); $a=str_repeat("x", 64*1024*1024);'
echo $?   # 1, and "shutdown-ran" is not printed
```

Before and after the deploy, request every site through the local nginx
(`curl -sk -o /dev/null -w '%{http_code}' --resolve domain:443:127.0.0.1 https://domain/`)
and compare the status codes.

## Build it yourself

Requirements: Linux x86_64, `unshare` (util-linux) with user namespaces enabled, `curl`,
`tar`, `xz`, about 5 GB of disk per Ubuntu release, and a subordinate ID range for your user:

```bash
grep "^$USER:" /etc/subuid /etc/subgid   # must print a range in both files
# if not: sudo usermod --add-subuids 100000-165535 --add-subgids 100000-165535 $USER
```

Then:

```bash
git clone https://github.com/seppegadeyne/php2shell-runcloud-builds.git
cd php2shell-runcloud-builds
./build.sh focal          # every version for 20.04 in matrix.tsv
./build.sh xenial 56 74   # only php56rc and php74rc for 16.04
ls out/                   # tarballs + SHA256SUMS
```

`build.sh` downloads the `ubuntu-base` root filesystem and the php.net tarballs, checks them
against `sources.sha256`, fetches RunCloud's support packages (checked against RunCloud's
index), installs the build dependencies inside the chroot and builds each row of
`matrix.tsv`. A patch that does not apply cleanly, or would need fuzz, stops the build.

Your own builds will not be byte-identical to the release assets (timestamps and the build
host name in `php -i` differ), but they are made from the same inputs. We rebuilt one or more
versions for every codename with this script from an empty work directory and compared them
with the release assets: same file list, same linked libraries.

### Your server has a different configure command?

RunCloud's flags can differ per package version. Compare before you trust a build:

```bash
/RunCloud/Packages/php74rc/bin/php -i | grep '^Configure Command' | sed 's/^Configure Command =>  //'
```

If it differs from `configure/configure-php74rc-<codename>.txt`, paste your output into that
file and build again.

### Test a build against your server's extensions

Copy the server's `/RunCloud/Packages/phpXXrc/lib/php/extensions/` and `/etc/phpXXrc/conf.d/`
into the chroot, put the new core next to them and check: `ldd` on every `.so` (no "not
found"), `php -m` shows the same module count as the server with no warnings, and a PHP-FPM
pool with `memory_limit = 16M` still serves a normal request after a request that allocates
64 MB.

## Generic mode: servers without RunCloud

The release tarballs only fit RunCloud (`/RunCloud/Packages/phpXXrc`, RunCloud's own libraries).
For a PHP you or your host compiled yourself (`/usr/local`, `/opt/...`, a panel's own PHP), the
scripts in `generic/` build a patched PHP with **that server's own configure command**, in the
server's own Ubuntu release, and swap it in place.

It is for builds that report their configure command in `php -i`. Distribution packages
(Ubuntu's `php8.1`, Debian, ondrej/Sury) do not; `collect.sh` then reads the package changelog
and says whether the vendor already fixed PHP2Shell. For those, update the package
(`apt-get install --only-upgrade 'php*'`) or ask the vendor; the generic mode skips them.

```bash
# 1) on the server (read-only): record every PHP CLI, FPM and CGI binary
mkdir -p /root/php2shell && cd /root/php2shell
RAW=https://raw.githubusercontent.com/seppegadeyne/php2shell-runcloud-builds/main/generic
curl -fLO $RAW/collect.sh
curl -fLO $RAW/deploy.sh             # needed in step 3
bash collect.sh                      # or: bash collect.sh /usr/local/sbin/php-fpm
# -> php2shell-profile-<host>-<date>.tar.gz

# 2) on the build machine (same requirements as "Build it yourself" above)
generic/build.sh php2shell-profile-web1-20261024-120000.tar.gz
# -> out/generic/web1/php7.4.33-php2shell-<job>.tar.gz + SHA256SUMS + SKIPPED.txt
# copy the tarball and SHA256SUMS to /root/php2shell on the server

# 3) back on the server, as root, in /root/php2shell
sha256sum -c --ignore-missing SHA256SUMS
bash deploy.sh php7.4.33-php2shell-<job>.tar.gz check      # test only
bash deploy.sh php7.4.33-php2shell-<job>.tar.gz            # swap
bash deploy.sh php7.4.33-php2shell-<job>.tar.gz rollback   # undo
```

What each step does:

- `collect.sh` changes nothing. Per binary it stores the version, SAPI, configure command,
  extension API, `php.ini` paths, built-in modules, linked libraries, SHA-256 and owning package.
  It notes libraries linked from outside `/lib` and `/usr/lib`, and it reports but skips what
  it cannot rebuild: an Apache `mod_php` (move those sites to PHP-FPM first) and LiteSpeed's
  `lsphp` (SAPI LiteSpeed; patch it through LiteSpeed's own packages).
- `build.sh` builds the newest release of the same branch (`generic/versions.tsv`: 5.6.40 to
  8.1.34 with the patch, 8.2+ the fixed php.net release), so the extension API stays the same
  and the server's other shared extensions keep loading. It installs the build dependencies of
  the release's own PHP source package, runs the configure command verbatim and refuses the
  result when the extension API differs or a built-in module is missing. Binaries with the same
  version and configure command are built once. A server that loads a shared `opcache.so`
  gets one built from the patched tree (8.1's fix also touches opcache); a configure command
  that builds none is refused. `--extra <tarball>` unpacks libraries at `/` in the build root
  for servers that link their own (for example an OpenSSL in `/opt`).
- `deploy.sh` refuses a target whose SHA-256 differs from the profile (the server changed:
  collect and build again), starts the new CLI with the server's real configuration and aborts
  on any warning, checks that an out-of-memory error no longer runs shutdown functions, backs
  the originals up once to `/root/php2shell-generic-backup/<job>/`, swaps by rename (also the
  shared extensions built from the core, only where the server has them), holds an owning
  package, and config-tests and restarts every systemd PHP-FPM service whose process runs a
  replaced binary. A failed test or start rolls back. An FPM outside systemd is not restarted:
  the script says so.

Only Ubuntu 16.04 to 24.04 servers are automated. For another distribution, build by hand in a
matching root filesystem with `generic/chroot-deps.sh` (Ubuntu package names) and
`generic/chroot-build.sh`.

Tested in chroots on our build host: a PHP 7.4.30 compiled into `/usr/local` with a shared
`opcache.so` and `php-cgi` on Ubuntu 20.04 (collect, build 7.4.33 with the patch, check, deploy, PHP-FPM
answering a FastCGI request with the new binary, out-of-memory exit 1, rollback back to the
original SHA-256), the same for a PHP 8.1.30 on Ubuntu 22.04 (8.1.34 with the patch, including
the rebuilt `opcache.so`), and Ubuntu 22.04's own `php8.1` package (skipped: the changelog shows the
vendor fix). Not yet run on a production server.

## Keep the mitigations

A patched binary is not a reason to remove the other layers:
`session.upload_progress.enabled = Off` (RunCloud's
`/etc/phpXXrc/conf.d/99-cve-2026-109618.ini`, active only after an FPM reload), Cloudflare's
managed rules for proxied domains, and admin tools such as phpMyAdmin behind an IP allowlist.
Ubuntu 16.04 to 20.04 are past standard support: the real fix is moving the sites to a
supported release.

## License

Scripts: MIT. Patches and binaries: PHP License 3.01 (`licenses/`). See `LICENSE`.

This product includes PHP software, freely available from <http://www.php.net/software/>.
