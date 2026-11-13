package runner

import (
	"flag"
	"fmt"
	"io"
	"os"
	"strings"
)

// ambiguityRule is the exact last line every design comment must end with.
const ambiguityRule = "Rule on ambiguity: silence in this design means STOP. If an unexpected decision arises, end with `DECISION: <question>`."

// cmdDesign dispatches the design subcommands.
func cmdDesign(args []string, stdout, stderr io.Writer) (int, error) {
	if len(args) == 0 {
		return 0, specErr("design needs a subcommand (want check)")
	}
	if args[0] != "check" {
		return 0, specErr("unknown design subcommand %q (want check)", args[0])
	}
	return cmdDesignCheck(args[1:], stdout, stderr)
}

// cmdDesignCheck applies collect's design checks to a comment body saved in a local file,
// plus the closing ambiguity line, without gh. With --repo-dir it also runs done_when.
func cmdDesignCheck(args []string, stdout, stderr io.Writer) (int, error) {
	fs := flag.NewFlagSet("design check", flag.ContinueOnError)
	fs.SetOutput(stderr)
	var repoDir string
	var issue int
	fs.StringVar(&repoDir, "repo-dir", "", "clean git checkout of the default branch to run done_when in")
	fs.IntVar(&issue, "issue", 0, "issue number the design must be for")
	if err := fs.Parse(args); err != nil {
		return 0, err
	}
	if fs.NArg() == 0 {
		return 0, specErr("design check needs FILE")
	}
	file := fs.Arg(0)
	if err := fs.Parse(fs.Args()[1:]); err != nil {
		return 0, err
	}
	if fs.NArg() > 0 {
		return 0, specErr("design check takes one FILE, got more positional arguments")
	}
	if issue < 0 {
		return 0, specErr("design check: --issue must be at least 1")
	}
	data, err := os.ReadFile(file)
	if err != nil {
		return 0, specErr("cannot read %s: %v", file, err)
	}

	status, err := designCheck(string(data), issue, repoDir, stdout)
	if nr, ok := err.(*notReady); ok {
		fmt.Fprintf(stdout, "DESIGN: status=INVALID reason=%s\n", strings.Join(strings.Fields(nr.msg), " "))
		return exitStopped, nil
	}
	if err != nil {
		return 0, err
	}
	fmt.Fprintf(stdout, "DESIGN: status=VALID file=%s expected_files=%d done_when=%s\n", file, status.expected, status.doneWhen)
	return exitOK, nil
}

type designCheckResult struct {
	expected int
	doneWhen string
}

func designCheck(body string, issue int, repoDir string, stdout io.Writer) (designCheckResult, error) {
	d, err := parseDesign(body, issue)
	if err != nil {
		return designCheckResult{}, err
	}
	if err := checkAmbiguityLine(body); err != nil {
		return designCheckResult{}, err
	}
	res := designCheckResult{expected: len(d.ExpectedFiles), doneWhen: "UNCHECKED"}
	if repoDir == "" {
		return res, nil
	}
	top, err := git(repoDir, "rev-parse", "--show-toplevel")
	if err != nil {
		return res, specErr("%s is not a git repository", repoDir)
	}
	checkout := strings.TrimSpace(top)
	if status, err := git(checkout, "status", "--porcelain"); err != nil || strings.TrimSpace(status) != "" {
		return res, specErr("checkout %s has uncommitted changes", checkout)
	}
	code, err := doneWhenRed(checkout, d.DoneWhen)
	if err != nil {
		return res, err
	}
	fmt.Fprintf(stdout, "DESIGN: check=done_when status=RED exit=%d\n", code)
	res.doneWhen = "RED"
	return res, nil
}

// checkAmbiguityLine requires the last non-blank line of body to be the ambiguity rule.
func checkAmbiguityLine(body string) error {
	lines := strings.Split(body, "\n")
	for i := len(lines) - 1; i >= 0; i-- {
		line := strings.TrimRight(lines[i], " \t\r\n\f\v")
		if line == "" {
			continue
		}
		if line == ambiguityRule {
			return nil
		}
		break
	}
	return notReadyf("last line must be the exact ambiguity rule")
}
