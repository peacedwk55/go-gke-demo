package main

import (
	"net"
	"testing"
)

// net_Listen binds an ephemeral loopback port for tests that need a real server.
func net_Listen(t *testing.T) (net.Listener, error) {
	t.Helper()
	return net.Listen("tcp", "127.0.0.1:0")
}
