package embeddednats

import (
	"context"
	"fmt"
	"os"
	"time"

	natsserver "github.com/nats-io/nats-server/v2/server"
)

// Options configures the embedded NATS JetStream server.
type Options struct {
	Host     string
	Port     int // -1 picks an ephemeral free port on Host
	StoreDir string
}

// Server wraps an embedded NATS server with persistent JetStream enabled.
type Server struct {
	ns *natsserver.Server
}

// Start boots an embedded NATS server bound privately to opts.Host with JetStream persistence.
func Start(ctx context.Context, opts Options) (*Server, error) {
	if opts.Host == "" {
		opts.Host = "127.0.0.1"
	}
	if opts.Port == 0 {
		opts.Port = -1
	}
	if opts.StoreDir == "" {
		return nil, fmt.Errorf("embedded nats store_dir is required")
	}
	if err := os.MkdirAll(opts.StoreDir, 0o750); err != nil {
		return nil, fmt.Errorf("create jetstream store_dir %q: %w", opts.StoreDir, err)
	}

	sOpts := &natsserver.Options{
		ServerName: "opendotnews-embedded",
		Host:       opts.Host,
		Port:       opts.Port,
		JetStream:  true,
		StoreDir:   opts.StoreDir,
		NoSigs:     true,
		NoLog:      true,
	}

	ns, err := natsserver.NewServer(sOpts)
	if err != nil {
		return nil, fmt.Errorf("create embedded nats server: %w", err)
	}

	go ns.Start()

	readyTimeout := 10 * time.Second
	if deadline, ok := ctx.Deadline(); ok {
		if rem := time.Until(deadline); rem < readyTimeout && rem > 0 {
			readyTimeout = rem
		}
	}
	if !ns.ReadyForConnections(readyTimeout) {
		ns.Shutdown()
		return nil, fmt.Errorf("embedded nats server did not become ready within %s", readyTimeout)
	}

	return &Server{ns: ns}, nil
}

// ClientURL returns the internal nats:// connection URL.
func (s *Server) ClientURL() string {
	return s.ns.ClientURL()
}

// Shutdown cleanly stops the embedded NATS server and waits for storage flush.
func (s *Server) Shutdown() {
	if s == nil || s.ns == nil {
		return
	}
	s.ns.Shutdown()
	s.ns.WaitForShutdown()
}
