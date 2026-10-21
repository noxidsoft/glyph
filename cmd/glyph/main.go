package main

import (
	"os"

	"github.com/noxidsoft/glyph/internal/cli"
)

func main() {
	os.Exit(cli.Execute())
}
