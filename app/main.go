package main

import (
	"context"
	"errors"
	"fmt"
	"log"
	"net/http"
	"os"
	"os/signal"
	"sync/atomic"
	"syscall"
	"time"
)

var version = "dev"

const startupDelay = 3 * time.Second

type application struct {
	pod          string
	node         string
	version      string
	started      time.Time
	now          func() time.Time
	shuttingDown atomic.Bool
}

func newApplication(now func() time.Time) *application {
	return &application{
		pod:     envOrLocal("POD_NAME"),
		node:    envOrLocal("NODE_NAME"),
		version: version,
		started: now(),
		now:     now,
	}
}

func envOrLocal(name string) string {
	if value := os.Getenv(name); value != "" {
		return value
	}
	return "local"
}

func (app *application) ServeHTTP(w http.ResponseWriter, r *http.Request) {
	switch r.URL.Path {
	case "/", "/readyz", "/livez":
	default:
		http.NotFound(w, r)
		return
	}
	if r.Method != http.MethodGet {
		w.Header().Set("Allow", http.MethodGet)
		http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
		return
	}

	w.Header().Set("Content-Type", "text/plain; charset=utf-8")
	switch r.URL.Path {
	case "/":
		fmt.Fprintf(w, "pod: %s\nnode: %s\nversion: %s\n", app.pod, app.node, app.version)
	case "/readyz":
		if app.shuttingDown.Load() || app.now().Sub(app.started) < startupDelay {
			http.Error(w, "not ready", http.StatusServiceUnavailable)
			return
		}
		fmt.Fprintln(w, "ok")
	case "/livez":
		fmt.Fprintln(w, "ok")
	}
}

func run() error {
	app := newApplication(time.Now)
	server := &http.Server{
		Addr:              "0.0.0.0:8080",
		Handler:           app,
		ReadHeaderTimeout: 5 * time.Second,
	}
	ctx, stop := signal.NotifyContext(context.Background(), syscall.SIGTERM, syscall.SIGINT)
	defer stop()

	serveErr := make(chan error, 1)
	go func() {
		log.Printf("starting address=%s pod=%s node=%s version=%s", server.Addr, app.pod, app.node, app.version)
		serveErr <- server.ListenAndServe()
	}()

	select {
	case err := <-serveErr:
		return err
	case <-ctx.Done():
	}

	app.shuttingDown.Store(true)
	log.Print("shutdown started; readiness disabled")
	shutdownCtx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	if err := server.Shutdown(shutdownCtx); err != nil {
		_ = server.Close()
		return fmt.Errorf("shutdown: %w", err)
	}
	if err := <-serveErr; err != nil && !errors.Is(err, http.ErrServerClosed) {
		return err
	}
	log.Print("shutdown complete")
	return nil
}

func main() {
	if err := run(); err != nil {
		log.Fatal(err)
	}
}
