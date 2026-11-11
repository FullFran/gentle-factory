package runner

import (
	"bytes"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"os"
	"strconv"
	"strings"
	"time"
)

// OTLP/HTTP JSON export of one invocation of `factory run` as a trace that follows
// the OpenTelemetry GenAI semantic conventions (pinned in docs/design/receipt-format.md).
// Standard library only: no retry, no batching, no background goroutine.

const (
	otlpScopeName  = "gentle-factory"
	otlpTimeout    = 10 * time.Second
	otlpSpanKind   = 1 // SPAN_KIND_INTERNAL
	otlpStatusErr  = 2 // STATUS_CODE_ERROR
	otlpProtoJSON  = "http/json"
	otlpTracesPath = "v1/traces"
)

// spanAttempt is one node attempt executed in this invocation: its receipt and start time.
type spanAttempt struct {
	p     *Predicate
	start time.Time
}

type otlpValue struct {
	StringValue *string  `json:"stringValue,omitempty"`
	IntValue    *string  `json:"intValue,omitempty"`
	DoubleValue *float64 `json:"doubleValue,omitempty"`
}

type otlpKV struct {
	Key   string    `json:"key"`
	Value otlpValue `json:"value"`
}

type otlpStatus struct {
	Code int `json:"code,omitempty"`
}

type otlpSpan struct {
	TraceID           string      `json:"traceId"`
	SpanID            string      `json:"spanId"`
	ParentSpanID      string      `json:"parentSpanId,omitempty"`
	Name              string      `json:"name"`
	Kind              int         `json:"kind"`
	StartTimeUnixNano string      `json:"startTimeUnixNano"`
	EndTimeUnixNano   string      `json:"endTimeUnixNano"`
	Attributes        []otlpKV    `json:"attributes,omitempty"`
	Status            *otlpStatus `json:"status,omitempty"`
}

type otlpScope struct {
	Name string `json:"name"`
}

type otlpScopeSpans struct {
	Scope otlpScope  `json:"scope"`
	Spans []otlpSpan `json:"spans"`
}

type otlpResource struct {
	Attributes []otlpKV `json:"attributes"`
}

type otlpResourceSpans struct {
	Resource   otlpResource     `json:"resource"`
	ScopeSpans []otlpScopeSpans `json:"scopeSpans"`
}

type otlpRequest struct {
	ResourceSpans []otlpResourceSpans `json:"resourceSpans"`
}

func strAttr(k, v string) otlpKV { return otlpKV{Key: k, Value: otlpValue{StringValue: &v}} }

func intAttr(k string, v int64) otlpKV {
	s := strconv.FormatInt(v, 10)
	return otlpKV{Key: k, Value: otlpValue{IntValue: &s}}
}

func doubleAttr(k string, v float64) otlpKV { return otlpKV{Key: k, Value: otlpValue{DoubleValue: &v}} }

func unixNano(t time.Time) string { return strconv.FormatInt(t.UnixNano(), 10) }

// rootSpanID is the parent id of the TRACEPARENT given to the nodes of this invocation.
func rootSpanID(rc *runCtx) string {
	parts := strings.Split(rc.traceparent, "-")
	if len(parts) != 4 {
		return ""
	}
	return parts[2]
}

// attemptSpan maps one receipt to its span. Only an allowlist of fields is read:
// never the command, notes, logs, prompts, outputs or file paths.
func attemptSpan(rc *runCtx, a spanAttempt) otlpSpan {
	p := a.p
	t := p.Telemetry
	span := otlpSpan{TraceID: t.TraceID, SpanID: t.SpanID, ParentSpanID: rootSpanID(rc), Kind: otlpSpanKind,
		StartTimeUnixNano: unixNano(a.start),
		EndTimeUnixNano:   unixNano(a.start.Add(time.Duration(t.DurationMS) * time.Millisecond))}
	nodeID := p.Step.NodeID
	if p.Step.NodeKind == "agent" {
		span.Name = "invoke_agent " + nodeID
		span.Attributes = append(span.Attributes, strAttr("gen_ai.operation.name", "invoke_agent"),
			strAttr("gen_ai.agent.name", nodeID))
		if t.GenAISystem != "" {
			span.Attributes = append(span.Attributes, strAttr("gen_ai.provider.name", t.GenAISystem))
		}
		if t.RequestModel != "" {
			span.Attributes = append(span.Attributes, strAttr("gen_ai.request.model", t.RequestModel))
		}
		if t.Tokens != nil {
			span.Attributes = append(span.Attributes, intAttr("gen_ai.usage.input_tokens", t.Tokens.InputTokens),
				intAttr("gen_ai.usage.output_tokens", t.Tokens.OutputTokens))
		}
		if t.TotalCostUSD != nil {
			span.Attributes = append(span.Attributes, doubleAttr("factory.total_cost_usd", *t.TotalCostUSD))
		}
	} else {
		span.Name = "execute_tool " + nodeID
		span.Attributes = append(span.Attributes, strAttr("gen_ai.operation.name", "execute_tool"),
			strAttr("gen_ai.tool.name", nodeID))
		if p.Outcome.ExitCode != nil {
			span.Attributes = append(span.Attributes, intAttr("factory.exit_code", int64(*p.Outcome.ExitCode)))
		}
	}
	span.Attributes = append(span.Attributes, intAttr("factory.attempt", int64(p.Step.Attempt)),
		strAttr("factory.outcome.status", p.Outcome.Status))
	if p.Outcome.Status != "success" {
		span.Attributes = append(span.Attributes, strAttr("error.type", p.Outcome.TerminalReason))
		span.Status = &otlpStatus{Code: otlpStatusErr}
	}
	return span
}

// traceRequest builds the ExportTraceServiceRequest for one invocation.
func traceRequest(rc *runCtx, attempts []spanAttempt, start, end time.Time) otlpRequest {
	// Same resource attribute names as nodeEnv's OTEL_RESOURCE_ATTRIBUTES.
	resource := []otlpKV{strAttr("service.name", "factory-"+rc.factory), strAttr("factory.name", rc.factory),
		strAttr("run.id", rc.runID), strAttr("task.id", rc.context.TaskID)}
	spans := []otlpSpan{{TraceID: rc.traceID, SpanID: rootSpanID(rc), Name: "invoke_workflow " + rc.factory,
		Kind: otlpSpanKind, StartTimeUnixNano: unixNano(start), EndTimeUnixNano: unixNano(end),
		Attributes: []otlpKV{strAttr("gen_ai.operation.name", "invoke_workflow")}}}
	for _, a := range attempts {
		spans = append(spans, attemptSpan(rc, a))
	}
	return otlpRequest{ResourceSpans: []otlpResourceSpans{{Resource: otlpResource{Attributes: resource},
		ScopeSpans: []otlpScopeSpans{{Scope: otlpScope{Name: otlpScopeName}, Spans: spans}}}}}
}

// exportTrace posts the invocation's trace when OTEL_EXPORTER_OTLP_ENDPOINT is set.
// It never fails the run: problems are one "OTLP:" line on stderr.
func exportTrace(rc *runCtx, attempts []spanAttempt, start, end time.Time, stderr io.Writer) {
	endpoint := os.Getenv("OTEL_EXPORTER_OTLP_ENDPOINT")
	if endpoint == "" {
		return
	}
	if proto := os.Getenv("OTEL_EXPORTER_OTLP_PROTOCOL"); proto != "" && proto != otlpProtoJSON {
		fmt.Fprintln(stderr, "OTLP: export skipped: only http/json is supported")
		return
	}
	body, err := json.Marshal(traceRequest(rc, attempts, start, end))
	if err != nil {
		fmt.Fprintf(stderr, "OTLP: export failed: %s\n", oneLine(err.Error()))
		return
	}
	url := strings.TrimSuffix(endpoint, "/") + "/" + otlpTracesPath
	client := &http.Client{Timeout: otlpTimeout}
	resp, err := client.Post(url, "application/json", bytes.NewReader(body))
	if err != nil {
		fmt.Fprintf(stderr, "OTLP: export failed: %s\n", oneLine(err.Error()))
		return
	}
	_, _ = io.Copy(io.Discard, resp.Body)
	_ = resp.Body.Close()
	if resp.StatusCode < 200 || resp.StatusCode > 299 {
		fmt.Fprintf(stderr, "OTLP: export failed: status %d\n", resp.StatusCode)
	}
}

func oneLine(s string) string { return strings.Join(strings.Fields(s), " ") }
