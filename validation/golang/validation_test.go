package validation

import "testing"

func TestRejectsEmptyRequestID(t *testing.T) {
	if err := Validate(RequestMeta{TraceID: "trace-1"}); err == nil { t.Fatal("expected validation error") }
}

func TestDecodeRejectsUnknownFields(t *testing.T) {
	_, err := DecodeAndValidate[RequestMeta]([]byte(`{"requestId":"req-1","traceId":"trace-1","userId":"client-supplied"}`))
	if err == nil { t.Fatal("expected unknown field error") }
}
