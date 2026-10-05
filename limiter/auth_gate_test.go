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

	if !CheckAuthGate("node210|uuid", "203.0.113.1") {
		t.Fatal("first connection must be rejected")
	}
	if !CheckAuthGate("node210|uuid", "203.0.113.1") {
		t.Fatal("second connection must be rejected")
	}
	if CheckAuthGate("node210|uuid", "203.0.113.1") {
		t.Fatal("third connection must be allowed")
	}
	if CheckAuthGate("node210|uuid", "203.0.113.1") {
		t.Fatal("authorized connection must remain allowed")
	}
}

func TestAuthGateWindowExpiryRestartsSequence(t *testing.T) {
	t.Setenv("V2NODE_AUTH_GATE", "true")
	t.Setenv("V2NODE_AUTH_GATE_REJECTS", "2")
	t.Setenv("V2NODE_AUTH_GATE_WINDOW", "25ms")
	t.Setenv("V2NODE_AUTH_GATE_TTL", "500ms")
	resetAuthGateForTest()

	if !CheckAuthGate("node210|uuid", "203.0.113.2") {
		t.Fatal("first connection must be rejected")
	}
	time.Sleep(40 * time.Millisecond)
	if !CheckAuthGate("node210|uuid", "203.0.113.2") {
		t.Fatal("expired second connection must restart and be rejected")
	}
	if !CheckAuthGate("node210|uuid", "203.0.113.2") {
		t.Fatal("new second connection must be rejected")
	}
	if CheckAuthGate("node210|uuid", "203.0.113.2") {
		t.Fatal("third connection must be allowed")
	}
}
