package dispatcher

import (
	"github.com/wyx2685/v2node/limiter"
	"github.com/xtls/xray-core/common"
	"github.com/xtls/xray-core/common/buf"
)

type authGateTouchWriter struct {
	writer buf.Writer
	user   string
	source string
}

func (w *authGateTouchWriter) WriteMultiBuffer(mb buf.MultiBuffer) error {
	if len(mb) > 0 {
		limiter.TouchAuthGate(w.user, w.source)
	}
	return w.writer.WriteMultiBuffer(mb)
}

func (w *authGateTouchWriter) Close() error {
	return common.Close(w.writer)
}

func wrapAuthGateTouchWriter(writer buf.Writer, user, source string) buf.Writer {
	if !limiter.AuthGateEnabled() {
		return writer
	}
	return &authGateTouchWriter{writer: writer, user: user, source: source}
}
