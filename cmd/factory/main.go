// Command factory is the gentle-factory node runner.
package main

import (
	"os"

	"github.com/FullFran/gentle-factory/internal/runner"
)

func main() {
	os.Exit(runner.Main(os.Args[1:], os.Stdout, os.Stderr))
}
