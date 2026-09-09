/*
 * argv_main.c — argv adapter for the three dateutils tools whose ONLY untrusted input is their
 * argument vector: dseq (FIRST [[INCREMENT] LAST]), dtest (DATE/TIME1 OP DATE/TIME2) and dzone
 * ([ZONENAME]... [DATE/TIME]..., which converts `now` when no date is given). None of them reads
 * stdin or a file, so a plain stdin/`@@` target could not reach their parsers.
 *
 * The FUZZ build compiles the src/ tools with `-Dmain=dateutils_tool_main` (fuzz build only — no
 * upstream file is edited, the additive invariant holds) and, for these three, links this file,
 * whose real main() reads the Mayhem-staged input file (`@@`), splits it into arguments — ONE
 * ARGUMENT PER LINE — and calls the renamed original with that argv. The tool's own option parsing
 * (yuck), date/duration parsers and comparison logic then run on attacker-controlled arguments
 * exactly as they would from a shell.
 *
 * Hangs: this adapter has no timer of any kind. Mayhem's per-input `timeout:` (5 s in every CLI
 * Mayhemfile) bounds each process; a pathological argument set (e.g. a dseq range spanning
 * millennia at one-second steps) is reported by Mayhem as a timeout.
 */
#include <stdio.h>
#include <string.h>

#ifndef TOOL_MAIN
#define TOOL_MAIN dateutils_tool_main
#endif

int TOOL_MAIN(int argc, char **argv);

#define MAX_ARGS  64
#define MAX_BYTES 65536

int main(int argc, char **argv)
{
	static char buf[MAX_BYTES + 1];
	char *av[MAX_ARGS + 2];
	int ac = 0;

	if (argc != 2) {
		fprintf(stderr, "usage: %s <argv-file>   (one tool argument per line)\n", argv[0]);
		return 2;
	}

	FILE *f = fopen(argv[1], "rb");
	if (f == NULL) {
		perror(argv[1]);
		return 2;
	}
	size_t n = fread(buf, 1, MAX_BYTES, f);
	fclose(f);
	buf[n] = '\0';

	av[ac++] = argv[0];
	char *p = buf;
	while (ac <= MAX_ARGS) {
		char *nl = strchr(p, '\n');
		if (nl != NULL) {
			*nl = '\0';
		}
		if (*p != '\0') {
			av[ac++] = p;
		}
		if (nl == NULL) {
			break;
		}
		p = nl + 1;
	}
	av[ac] = NULL;

	return TOOL_MAIN(ac, av);
}
