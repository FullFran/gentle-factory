// Package pipeline embeds the repository-agnostic factory pipeline (spec, prompts and
// code nodes) so an installed binary can run it without a checkout of this repository.
package pipeline

import (
	"embed"
	"fmt"
	"io/fs"
	"os"
	"path/filepath"
	"strings"
)

//go:embed factory.json *.md *.sh
var files embed.FS

// SpecName is the spec file inside a materialized pipeline.
const SpecName = "factory.json"

// Materialize writes the embedded pipeline into dir and returns the path of its spec.
// Specs resolve prompts and {spec_dir} relative to the spec file, so the files must
// live on disk next to it.
func Materialize(dir string) (string, error) {
	err := fs.WalkDir(files, ".", func(name string, d fs.DirEntry, err error) error {
		if err != nil || d.IsDir() {
			return err
		}
		data, err := files.ReadFile(name)
		if err != nil {
			return err
		}
		mode := os.FileMode(0o644)
		if strings.HasSuffix(name, ".sh") {
			mode = 0o755
		}
		return os.WriteFile(filepath.Join(dir, name), data, mode)
	})
	if err != nil {
		return "", fmt.Errorf("cannot materialize the embedded pipeline: %w", err)
	}
	return filepath.Join(dir, SpecName), nil
}
