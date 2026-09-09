/*
 * libFuzzer harness for dateutils' date/time string parser.
 *
 * dt_strpdt(str, fmt, ep) is the public entry point of dateutils' parsing
 * engine (lib/dt-core.c). Called with fmt == NULL it dispatches to
 * __strpdt_std(), the format-autodetecting parser that walks every supported
 * date/time representation (ymd, ymcw, ywd, bizda, daisy, julian/lilian day
 * numbers, ISO week dates, times, and date+time "sandwiches"). This is the
 * exact code path the `dconv`/`strptime`/`dseq` command-line tools drive when
 * a user hands them a date string with no explicit input format — a rich,
 * self-contained parser with no file or global state: an ideal in-process
 * fuzz target.
 *
 * dt_strpdtdur(str, ep) parses a duration string ("+1w", "2020-01-01" as a
 * relative span, etc.) through a sibling code path; exercised too so a single
 * target covers both the absolute and relative parsers.
 *
 * Byte-in only, NO file I/O: the fuzzer bytes are copied into a heap buffer and
 * NUL-terminated (the parsers are C-string based), then fed to both parsers.
 */
#include <stdint.h>
#include <stddef.h>
#include <stdlib.h>
#include <string.h>

#include "dt-core.h"   /* struct dt_dt_s, dt_strpdt(), dt_strpdtdur() */

int LLVMFuzzerTestOneInput(const uint8_t *data, size_t size)
{
	char *buf = (char *)malloc(size + 1U);
	if (buf == NULL) {
		return 0;
	}
	if (size) {
		memcpy(buf, data, size);
	}
	buf[size] = '\0';

	/* absolute date/time, format autodetected (fmt == NULL) */
	char *ep = NULL;
	struct dt_dt_s d = dt_strpdt(buf, NULL, &ep);
	(void)d;

	/* relative duration parser over the same bytes */
	char *dep = NULL;
	struct dt_dtdur_s dur = dt_strpdtdur(buf, &dep);
	(void)dur;

	free(buf);
	return 0;
}
