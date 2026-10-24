# Patches

Every patch fixes PHP2Shell (CVE-2026-109618 and CVE-2026-109619) and applies with
`patch -p1` to the unmodified php.net tarball. None needs fuzz; some hunks need a line offset.

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
