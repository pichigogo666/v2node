package limiter

import (
	"os"
	"sync"
	"testing"
	"time"
)

func resetAuthGateForTest() {
	authGateStates = sync.Map{}
	authGateLastGC.Store(0)
	initAuthGate()
}

func TestAuthGateRejectsTwiceAndAllowsThird(t *testing.T) {
	t.Setenv("V2NODE_AUTH_GATE", "true")
	t.Setenv("V2NODE_AUTH_GATE_REJECTS", "2")
	t.Setenv("V2NODE_AUTH_GATE_WINDOW", "200ms")
	t.Setenv("V2NODE_AUTH_GATE_TTL", "500ms")
	resetAuthGateForTest()
	t.Cleanup(func() {
		_ = os.Unsetenv("V2NODE_AUTH_GATE")
		resetAuthGateForTest()
	})

	if !CheckAuthGate("node210|uuid", "203.0.113.1", "example.com", 443) {
		t.Fatal("first connection must be rejected")
	}
	if !CheckAuthGate("node210|uuid", "203.0.113.1", "example.com", 443) {
		t.Fatal("second connection must be rejected")
	}
	if CheckAuthGate("node210|uuid", "203.0.113.1", "example.com", 443) {
		t.Fatal("third connection must be allowed")
	}
	if CheckAuthGate("node210|uuid", "203.0.113.1", "example.com", 443) {
		t.Fatal("authorized connection must remain allowed")
	}
}

func TestAuthGateWindowExpiryRestartsSequence(t *testing.T) {
	t.Setenv("V2NODE_AUTH_GATE", "true")
	t.Setenv("V2NODE_AUTH_GATE_REJECTS", "2")
	t.Setenv("V2NODE_AUTH_GATE_WINDOW", "25ms")
	t.Setenv("V2NODE_AUTH_GATE_TTL", "500ms")
	resetAuthGateForTest()

	if !CheckAuthGate("node210|uuid", "203.0.113.2", "example.com", 443) {
		t.Fatal("first connection must be rejected")
	}
	time.Sleep(40 * time.Millisecond)
	if !CheckAuthGate("node210|uuid", "203.0.113.2", "example.com", 443) {
		t.Fatal("expired second connection must restart and be rejected")
	}
	if !CheckAuthGate("node210|uuid", "203.0.113.2", "example.com", 443) {
		t.Fatal("new second connection must be rejected")
	}
	if CheckAuthGate("node210|uuid", "203.0.113.2", "example.com", 443) {
		t.Fatal("third connection must be allowed")
	}
}

func TestAuthGateBypassesGstaticConnectivityProbe(t *testing.T) {
	t.Setenv("V2NODE_AUTH_GATE", "true")
	t.Setenv("V2NODE_AUTH_GATE_REJECTS", "2")
	t.Setenv("V2NODE_AUTH_GATE_WINDOW", "200ms")
	t.Setenv("V2NODE_AUTH_GATE_TTL", "500ms")
	resetAuthGateForTest()

	for _, test := range []struct {
		host string
		port uint16
	}{
		{host: "www.gstatic.com", port: 80},
		{host: "WWW.GSTATIC.COM.", port: 443},
	} {
		if CheckAuthGate("node210|uuid", "203.0.113.3", test.host, test.port) {
			t.Fatalf("connectivity probe %s:%d must bypass the gate", test.host, test.port)
		}
	}

	if !CheckAuthGate("node210|uuid", "203.0.113.3", "example.com", 443) {
		t.Fatal("bypass traffic must not authorize unrelated destinations")
	}
}

func TestAuthGateDoesNotBypassOtherGstaticPorts(t *testing.T) {
	t.Setenv("V2NODE_AUTH_GATE", "true")
	t.Setenv("V2NODE_AUTH_GATE_REJECTS", "2")
	resetAuthGateForTest()

	if !CheckAuthGate("node210|uuid", "203.0.113.4", "www.gstatic.com", 8443) {
		t.Fatal("non-HTTP(S) gstatic destination must still use the gate")
	}
}
