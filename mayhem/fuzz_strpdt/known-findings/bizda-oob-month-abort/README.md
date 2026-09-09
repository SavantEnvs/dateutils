# fuzz_strpdt — reachable abort in the bizda business-day parser (out-of-range month)

**Reproducer:** `reproducer.bin` (16 bytes: `01615-0000-3bCC\x87`, an ASCII date-like
string ending in a stray high byte).

**Crash:** `dt_strpdt(input, NULL, &ep)` autodetects a "bizda" (business-day) date and calls
`__get_bdays()` (`lib/bizda.c`). That routine does:

```c
unsigned int md = __get_mdays(y, m);
assert((signed int)md - 28 >= 0);            /* bizda.c:279 */
unsigned int rd = (unsigned int)(md - 28U);
...
default: abort();                            /* bizda.c:304 */
```

When the parsed month `m` is out of range (here the `-0000-` field yields month 0),
`__get_mdays(y, 0)` returns a value `< 28`, so:

- with `assert()` enabled (dateutils' default build, as shipped): the
  `assert((signed int)md - 28 >= 0)` at `bizda.c:279` fires → `abort()`.
- with `-DNDEBUG`: `rd = md - 28U` underflows and/or the `switch` falls through to the
  explicit `default: abort()` at `bizda.c:304`.

Either way an attacker-controlled string reaches an `abort()` through the public
`dt_strpdt()` parser — a denial-of-service / robustness defect in a library that is
meant to parse untrusted date input.

**Call path:**
`dt_strpdt` (dt-core.c:622) → `__strpdt_std` (dt-core-strpf.c:176) →
`__strpd_std` (date-core-strpf.c:171) → `__guess_dtyp` (date-core.c:905) →
`__get_bdays` (bizda.c).

**Impact:** DoS — any tool that parses an untrusted date via the autodetecting parser
(`dconv`, `strptime`, `dseq`, `dgrep`, …) can be crashed with a crafted string.

**One-line fix:** range-check the month in `__guess_dtyp`/`__get_bdays` before indexing the
month-day table (reject `m < 1 || m > 12` and return the "unknown date type" sentinel instead
of calling `__get_bdays` with a bogus month).

**Reproduce:**
```
/mayhem/fuzz_strpdt-standalone mayhem/fuzz_strpdt/known-findings/bizda-oob-month-abort/reproducer.bin
# or
/mayhem/fuzz_strpdt -runs=1 mayhem/fuzz_strpdt/known-findings/bizda-oob-month-abort/reproducer.bin
```

Note: this reproducer is intentionally kept OUT of `testsuite/` — a crashing seed would be
replayed on every Mayhem run and stall the campaign.
