# Patches

Two patches per PHP version, applied in this order with `patch -p1` to the unmodified php.net
tarball (`matrix.tsv` lists them per build). None needs fuzz; some hunks need a line offset.

- `php-X.Y-php2shell.patch`: PHP2Shell (CVE-2026-109618 and CVE-2026-109619), October 2026.
- `php-X.Y-phpaftershell.patch`: phpAfterShell (CVE-2026-126714), November 2026.

## PHP2Shell

| File | For | Origin |
| --- | --- | --- |
| `php-5.6-php2shell.patch` | 5.6.40 | Ondřej Surý, Debian source package php5.6, `debian/patches/0261-Avoid-state-corruption-via-bailout.patch` |
| `php-7.0-php2shell.patch` | 7.0.33 | Surý php7.0: `0211-backport-ZSTR_MAX_LEN` + `0230-Avoid-state-corruption-via-bailout`, concatenated |
| `php-7.1-php2shell.patch` | 7.1.33 | Surý php7.1: `0167` (ZSTR_MAX_LEN) + `0186` (bailout), concatenated |
| `php-7.2-php2shell.patch` | 7.2.34 | Surý php7.2: `0135` (ZSTR_MAX_LEN) + `0159` (bailout), concatenated |
| `php-7.3-php2shell.patch` | 7.3.33 | Surý php7.3: `0107` (ZSTR_MAX_LEN) + `0139` (bailout), concatenated |
| `php-7.4-php2shell.patch` | 7.4.33 | php-src commit `712e60f9ed`, branch `PHP-7.4-CVE-2026-109618-109619` |
| `php-8.0-php2shell.patch` | 8.0.30 | php-src commit `82f8f31b16`, branch `PHP-8.0-CVE-2026-109618-109619` |
| `php-8.1-php2shell.patch` | 8.1.34 | php-src commit `1d7dec178a`, branch `PHP-8.1-CVE-2026-109618-109619` |

The fix itself, "Avoid state corruption via bailout", is by Arnaud Le Blanc, co-authored by
Ilija Tovilo (PHP project). The 5.6 to 7.3 ports are Ondřej Surý's work for
[packages.sury.org](https://packages.sury.org/php/). `backport ZSTR_MAX_LEN` is by Remi Collet;
7.0 to 7.3 need it because the bailout patch uses that macro.

The patches are redistributed unchanged (only renamed and, for 7.0 to 7.3, two files joined)
under the PHP License 3.01, see `../licenses/`. Checksums are in `../sources.sha256`.

PHP 5.5 is not covered: hunk 10 of the 5.6 patch fails in `Zend/zend_alloc.c` and no other
patch exists.

## phpAfterShell

| File | For | Origin |
| --- | --- | --- |
| `php-5.6-phpaftershell.patch` | 5.6.40 | Surý php5.6 `5.6.40-109`: `0397-Fix-GHSA-fm2m-fjf5-v3cp-RCE-via-corrupted-session-fi.patch` |
| `php-7.0-phpaftershell.patch` | 7.0.33 | Surý php7.0 `7.0.33-97`: `0359-Fix-GHSA-fm2m-...` |
| `php-7.1-phpaftershell.patch` | 7.1.33 | Surý php7.1 `7.1.33-85`: `0306-Fix-GHSA-fm2m-...` |
| `php-7.2-phpaftershell.patch` | 7.2.34 | Surý php7.2 `7.2.34-70`: `0265-Fix-GHSA-fm2m-...` |
| `php-7.3-phpaftershell.patch` | 7.3.33 | Surý php7.3 `7.3.33-41`: `0238-Fix-GHSA-fm2m-...` |
| `php-7.4-phpaftershell.patch` | 7.4.33 | Surý php7.4 `7.4.33-37`: `0210-Fix-GHSA-fm2m-...` |
| `php-8.0-phpaftershell.patch` | 8.0.30 | Surý php8.0 `8.0.30-31`: `0176-Fix-GHSA-fm2m-...` |
| `php-8.1-phpaftershell.patch` | 8.1.34 | Surý php8.1 `8.1.34-14`: `0118-Fix-GHSA-fm2m-...` |

The fix, "Fix GHSA-fm2m-fjf5-v3cp: RCE via corrupted session file", is by Ilija Tovilo (PHP
project; the patch headers cite php-src commit `41c0941ae2`, the PHP-8.2 branch has it as
`e2d3cee9ad`; advisory
[GHSA-fm2m-fjf5-v3cp](https://github.com/php/php-src/security/advisories/GHSA-fm2m-fjf5-v3cp)),
cherry-picked to the old branches by Ondřej Surý. It changes one place in
`ext/session/mod_files.c`: the files session handler now always truncates the session file
before it writes the new data, and stops the write when truncating fails. Before, it only
truncated when the new data was shorter, so an interrupted write could leave the tail of the
old session behind.

The patches are redistributed unchanged (only renamed). Taken from the Debian source packages
on packages.sury.org (`jammy` builds of November 18, 2026).

## Not included

The November 19, 2026 releases fixed more security bugs (13 in 8.3.37). Surý backported most of them to 5.6 to
8.1, but this repository only carries PHP2Shell and phpAfterShell. See "What these builds do not
fix" in the main README.
