/*
 * stdin_main.c — stdin input adapter for the stdin-reading dateutils command-line targets
 * (strptime, dadd, dconv, ddiff, dgrep, dround).
 *
 * The FUZZ build compiles the src/ tools with `-Dmain=dateutils_tool_main` (fuzz build only — no
 * upstream file is edited; the clean oracle build keeps upstream's real main()) and links this
 * file, whose real main() opens the Mayhem-staged input file as stdin and calls the renamed
 * original with the rest of the argv unchanged, so the tool's real command-line interface is what
 * Mayhem drives.
 *
 * STDIN_FROM_LAST_ARG (compile-time, used for every stdin-reading dateutils tool): the LAST argv
 * element is the Mayhem-staged input file (`@@`); it is opened as the process's stdin (the shell's
 * `tool < file` redirection, done in-process) and dropped from the argv handed to the tool, so the
 * tool still reads its date stream from stdin exactly as in production. Reason: with the fuzz
 * bytes delivered on the process's real stdin, Mayhem's symbolic-execution worker died ("SE exited
 * abnormally (1)") on 5-6 of these six targets in two consecutive confirmation runs once they
 * started from an accumulated corpus, while every `@@`-fed target in the same runs (dseq, dtest,
 * dzone — same library, same wrappers) completed. File-staged input is the fleet's known-green
 * shape for raw targets (docs/netnew-worker-prompt.md).
 *
 * Hangs: this adapter has no timer of any kind. Each input is its own process (raw, non-libFuzzer
 * target) and Mayhem's per-input `timeout:` (5 s in every CLI Mayhemfile) bounds it; a
 * non-terminating input is reported by Mayhem as a timeout, which is the correct finding.
 */
#include <stdio.h>

#ifndef TOOL_MAIN
#define TOOL_MAIN dateutils_tool_main
#endif

int TOOL_MAIN(int argc, char **argv);

int main(int argc, char **argv)
{
#ifdef STDIN_FROM_LAST_ARG
	if (argc < 2) {
		fprintf(stderr, "usage: %s [tool args...] <input-file>\n", argv[0]);
		return 2;
	}
	if (freopen(argv[argc - 1], "r", stdin) == NULL) {
		perror(argv[argc - 1]);
		return 2;
	}
	argv[argc - 1] = NULL;
	argc--;
#endif
	return TOOL_MAIN(argc, argv);
}
