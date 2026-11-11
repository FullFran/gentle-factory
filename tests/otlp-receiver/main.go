// Command otlp-receiver is a test double for an OTLP/HTTP collector.
//
// It listens on 127.0.0.1:0, prints "LISTEN <port>" once, appends every request
// as one line "<method> <path> <content-type> <body>" to the file named by its
// first argument, and answers 200 with "{}".
package main

import (
	"bytes"
	"encoding/json"
	"fmt"
	"io"
	"net"
	"net/http"
	"os"
	"strings"
	"sync"
)

func main() {
	if len(os.Args) != 2 {
		fmt.Fprintln(os.Stderr, "usage: otlp-receiver FILE")
		os.Exit(2)
	}
	file := os.Args[1]
	ln, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
	fmt.Printf("LISTEN %d\n", ln.Addr().(*net.TCPAddr).Port)
	var mu sync.Mutex
	handler := http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		body, _ := io.ReadAll(r.Body)
		var compact bytes.Buffer
		if json.Compact(&compact, body) != nil {
			compact.Reset()
			compact.WriteString(strings.Join(strings.Fields(string(body)), " "))
		}
		line := fmt.Sprintf("%s %s %s %s\n", r.Method, r.URL.Path, r.Header.Get("Content-Type"), compact.String())
		mu.Lock()
		f, err := os.OpenFile(file, os.O_CREATE|os.O_APPEND|os.O_WRONLY, 0o644)
		if err == nil {
			_, _ = f.WriteString(line)
			_ = f.Close()
		}
		mu.Unlock()
		w.Header().Set("Content-Type", "application/json")
		_, _ = w.Write([]byte("{}"))
	})
	if err := http.Serve(ln, handler); err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
}
