// Command catalog builds and checks catalog/catalog.json, the HCS-0001 catalog of the
// pipeline embedded in this binary.
package main

import (
	"errors"
	"flag"
	"fmt"
	"io"
	"os"
	"path/filepath"

	"github.com/FullFran/gentle-factory/internal/catalog"
)

const usage = `usage: catalog <command> [flags]

commands:
  build [--root DIR] [--archive FILE]  write catalog/catalog.json from the embedded pipeline
                                       (and, with --archive, the package bytes to FILE)
  check [--root DIR]                   exit 1 when catalog/catalog.json is not up to date

--root defaults to the nearest directory above the working directory holding go.mod.
`

func main() { os.Exit(run(os.Args[1:], os.Stderr)) }

func run(args []string, stderr io.Writer) int {
	if len(args) == 0 {
		fmt.Fprint(stderr, usage)
		return 2
	}
	fs := flag.NewFlagSet(args[0], flag.ContinueOnError)
	fs.SetOutput(io.Discard)
	root := fs.String("root", "", "repository root")
	var archive *string
	switch args[0] {
	case "build":
		archive = fs.String("archive", "", "write the package bytes to this file")
	case "check":
	default:
		fmt.Fprint(stderr, usage)
		return 2
	}
	if err := fs.Parse(args[1:]); err != nil || fs.NArg() > 0 {
		fmt.Fprint(stderr, usage)
		return 2
	}
	dir := *root
	if dir == "" {
		var err error
		if dir, err = findRoot(); err != nil {
			fmt.Fprintln(stderr, "catalog:", err)
			return 1
		}
	}
	if args[0] == "check" {
		probs, warnings := catalog.Check(dir)
		for _, w := range warnings {
			fmt.Fprintln(stderr, "WARN", w)
		}
		for _, p := range probs {
			fmt.Fprintln(stderr, p)
		}
		if len(probs) > 0 {
			return 1
		}
		return 0
	}
	if err := build(dir, *archive); err != nil {
		fmt.Fprintln(stderr, "catalog:", err)
		return 1
	}
	return 0
}

func build(root, archive string) error {
	src, err := catalog.ReadSource(root)
	if err != nil {
		return err
	}
	c, tgz, err := catalog.Build(src)
	if err != nil {
		return err
	}
	data, err := catalog.Marshal(c)
	if err != nil {
		return err
	}
	if err := os.WriteFile(filepath.Join(root, catalog.CatalogPath), data, 0o644); err != nil {
		return err
	}
	if archive != "" {
		return os.WriteFile(archive, tgz, 0o644)
	}
	return nil
}

func findRoot() (string, error) {
	dir, err := os.Getwd()
	if err != nil {
		return "", err
	}
	for {
		if _, err := os.Stat(filepath.Join(dir, "go.mod")); err == nil {
			return dir, nil
		}
		parent := filepath.Dir(dir)
		if parent == dir {
			return "", errors.New("no go.mod found above the working directory; use --root")
		}
		dir = parent
	}
}
