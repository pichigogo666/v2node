package limiter

import (
	"os"
	"strconv"
	"strings"
	"sync"
	"sync/atomic"
	"time"

	log "github.com/sirupsen/logrus"
)

type authGateConfig struct {
	enabled bool
	rejects int
	window  time.Duration
	ttl     time.Duration
}

type authGateState struct {
	sync.Mutex
	rejected        int
	pendingUntil    time.Time
	authorizedUntil time.Time
	lastSeen        time.Time
}

var authGateConfigValue authGateConfig
var authGateStates sync.Map
var authGateLastGC atomic.Int64

func initAuthGate() {
	authGateConfigValue = authGateConfig{
		enabled: parseBoolEnv("V2NODE_AUTH_GATE"),
		rejects: parseIntEnv("V2NODE_AUTH_GATE_REJECTS", 2, 1, 10),
		window:  parseDurationEnv("V2NODE_AUTH_GATE_WINDOW", 10*time.Second),
		ttl:     parseDurationEnv("V2NODE_AUTH_GATE_TTL", 30*time.Minute),
	}
	if authGateConfigValue.enabled {
		log.WithFields(log.Fields{
			"rejects": authGateConfigValue.rejects,
			"window":  authGateConfigValue.window,
			"ttl":     authGateConfigValue.ttl,
		}).Info("VLESS user authentication gate enabled")
	}
}

func parseBoolEnv(name string) bool {
	value, err := strconv.ParseBool(strings.TrimSpace(os.Getenv(name)))
	return err == nil && value
}

func parseIntEnv(name string, fallback, min, max int) int {
	value, err := strconv.Atoi(strings.TrimSpace(os.Getenv(name)))
	if err != nil || value < min || value > max {
		return fallback
	}
	return value
}

func parseDurationEnv(name string, fallback time.Duration) time.Duration {
	value, err := time.ParseDuration(strings.TrimSpace(os.Getenv(name)))
	if err != nil || value <= 0 {
		return fallback
	}
	return value
}

func AuthGateEnabled() bool {
	return authGateConfigValue.enabled
}

func CheckAuthGate(taguuid, ip string) bool {
	cfg := authGateConfigValue
	if !cfg.enabled {
		return false
	}

	now := time.Now()
	gcAuthGate(now, cfg)
	key := taguuid + "\x00" + ip
	value, _ := authGateStates.LoadOrStore(key, &authGateState{})
	state := value.(*authGateState)
	state.Lock()
	defer state.Unlock()

	if now.Before(state.authorizedUntil) {
		state.authorizedUntil = now.Add(cfg.ttl)
		state.lastSeen = now
		return false
	}

	if !state.pendingUntil.IsZero() && now.After(state.pendingUntil) {
		state.rejected = 0
	}
	state.rejected++
	state.pendingUntil = now.Add(cfg.window)
	state.lastSeen = now

	fields := log.Fields{
		"node":      authGateNodeTag(taguuid),
		"source_ip": ip,
		"attempt":   state.rejected,
	}
	if state.rejected >= cfg.rejects {
		state.rejected = 0
		state.pendingUntil = time.Time{}
		state.authorizedUntil = now.Add(cfg.ttl)
		log.WithFields(fields).Info("VLESS user authentication gate armed; next connection will be allowed")
	} else {
		log.WithFields(fields).Info("VLESS user authentication gate rejected connection")
	}
	return true
}

func TouchAuthGate(taguuid, ip string) {
	if !authGateConfigValue.enabled {
		return
	}
	value, ok := authGateStates.Load(taguuid + "\x00" + ip)
	if !ok {
		return
	}
	state := value.(*authGateState)
	state.Lock()
	defer state.Unlock()
	if state.authorizedUntil.IsZero() {
		return
	}
	now := time.Now()
	state.authorizedUntil = now.Add(authGateConfigValue.ttl)
	state.lastSeen = now
}

func gcAuthGate(now time.Time, cfg authGateConfig) {
	last := authGateLastGC.Load()
	if now.UnixNano()-last < int64(time.Minute) || !authGateLastGC.CompareAndSwap(last, now.UnixNano()) {
		return
	}
	cutoff := now.Add(-(cfg.ttl + cfg.window + time.Minute))
	authGateStates.Range(func(key, value any) bool {
		state := value.(*authGateState)
		state.Lock()
		stale := state.lastSeen.Before(cutoff)
		state.Unlock()
		if stale {
			authGateStates.CompareAndDelete(key, value)
		}
		return true
	})
}

func authGateNodeTag(taguuid string) string {
	if index := strings.IndexByte(taguuid, '|'); index >= 0 {
		return taguuid[:index]
	}
	return taguuid
}
