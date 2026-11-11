package runner

import (
	"encoding/json"
	"fmt"
	"io"
	"math"
	"os"
	"path/filepath"
	"regexp"
	"strconv"
	"strings"
	"time"
	"unicode"
)

// The status file (#43) is what the panel copies out of the box: an allow-listed, bounded
// view of the watcher, the run in progress, the newest runs, the queue and today's totals.
// It never holds prompts, outputs, feedback, logs, tokens or paths. Its schema is
// schemas/factory-status.schema.json.

const (
	statusVersion   = "1.0"
	maxLastRuns     = 20
	maxStatusRepos  = 20
	maxQueueIssues  = 200
	maxStopDetail   = 200
	maxStatusModel  = 100
	maxStatusRepo   = 140
	maxStatusNodeID = 64
	maxStatusCost   = 100000
)

var (
	statusRepoRe   = regexp.MustCompile(`^[A-Za-z0-9][A-Za-z0-9-]*/[A-Za-z0-9._-]+$`)
	statusNodeRe   = regexp.MustCompile(`^[a-z0-9_-]+$`)
	statusRunIDRe  = regexp.MustCompile(`^run_[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$`)
	githubPRURLRe  = regexp.MustCompile(`^https://github\.com/[^/]+/[^/]+/pull/([1-9][0-9]{0,9})$`)
	statusStopCode = map[string]bool{
		"user_decision_required": true, "step_failed": true, "gate_failed": true, "timeout": true,
		"max_turns_exceeded": true, "budget_exceeded": true, "engine_error": true, "engine_output_invalid": true,
		"misconfigured": true, "read_only_modified": true, "protected_path_modified": true,
		"unexpected_path_modified": true, "same_failure_signature": true, "retries_exhausted": true,
		"archive_failed": true,
	}
)

type factoryStatus struct {
	SchemaVersion string         `json:"schema_version"`
	UpdatedAt     string         `json:"updated_at"`
	Watcher       *watcherStatus `json:"watcher,omitempty"`
	CurrentRun    *currentRun    `json:"current_run,omitempty"`
	LastRuns      []runRecord    `json:"last_runs"`
	Queue         []queueEntry   `json:"queue"`
	Today         dayTotals      `json:"today"`
}

type watcherStatus struct {
	StartedAt    string   `json:"started_at"`
	LastPassAt   string   `json:"last_pass_at,omitempty"`
	Slots        int      `json:"slots"`
	SlotsBusy    int      `json:"slots_busy"`
	Repositories []string `json:"repositories"`
}

type currentRun struct {
	RunID      string `json:"run_id"`
	Repository string `json:"repository"`
	Issue      int    `json:"issue"`
	StartedAt  string `json:"started_at"`
	NodeID     string `json:"node_id,omitempty"`
	NodeKind   string `json:"node_kind,omitempty"`
	Attempt    int    `json:"attempt,omitempty"`
}

type runRecord struct {
	RunID        string  `json:"run_id"`
	Repository   string  `json:"repository"`
	Issue        int     `json:"issue"`
	StartedAt    string  `json:"started_at"`
	FinishedAt   string  `json:"finished_at"`
	Status       string  `json:"status"`
	StopCode     string  `json:"stop_code,omitempty"`
	StopDetail   string  `json:"stop_detail,omitempty"`
	TotalCostUSD float64 `json:"total_cost_usd"`
	DurationMS   int64   `json:"duration_ms"`
	Retries      int     `json:"retries"`
	PRNumber     int     `json:"pr_number,omitempty"`
	RequestModel string  `json:"request_model,omitempty"`
}

type queueEntry struct {
	Repository string `json:"repository"`
	Issues     []int  `json:"issues"`
}

type dayTotals struct {
	Date         string  `json:"date"`
	Runs         int     `json:"runs"`
	Completed    int     `json:"completed"`
	Stopped      int     `json:"stopped"`
	TotalCostUSD float64 `json:"total_cost_usd"`
}

func statusTime(t time.Time) string { return t.UTC().Format(time.RFC3339) }

// statusPathFor is the status file under a state directory.
func statusPathFor(stateDir string) string {
	return filepath.Join(stateDir, "gentle-factory", "status.json")
}

// loadStatus reads the previous file; a missing, invalid or other-version file gives an empty status.
func loadStatus(path string) *factoryStatus {
	s := &factoryStatus{}
	data, err := os.ReadFile(path)
	if err != nil || decodeStrictBytes(data, s) != nil || s.SchemaVersion != statusVersion {
		return &factoryStatus{}
	}
	return s
}

// updateStatus loads the file, applies change, bounds it and writes it atomically. A failure
// is one STATUS line on out and never anything more: the file must not change a run.
func updateStatus(path string, out io.Writer, change func(*factoryStatus)) {
	if path == "" {
		return
	}
	s := loadStatus(path)
	now := time.Now().UTC()
	if day := now.Format("2006-01-02"); s.Today.Date != day {
		s.Today = dayTotals{Date: day}
	}
	change(s)
	s.SchemaVersion, s.UpdatedAt = statusVersion, statusTime(now)
	s.bound()
	if err := writeStatus(path, s); err != nil {
		fmt.Fprintf(out, "STATUS: write failed reason=%s\n", strings.Join(strings.Fields(scrubPaths(err.Error())), " "))
	}
}

func writeStatus(path string, s *factoryStatus) (err error) {
	data, err := json.MarshalIndent(s, "", "  ")
	if err != nil {
		return err
	}
	dir := filepath.Dir(path)
	if _, serr := os.Stat(dir); serr != nil {
		if err := os.MkdirAll(dir, 0o755); err != nil {
			return err
		}
		if err := os.Chmod(dir, 0o755); err != nil {
			return err
		}
	}
	tmp, err := os.CreateTemp(dir, ".status-*.tmp")
	if err != nil {
		return err
	}
	defer func() {
		if err != nil {
			_ = tmp.Close()
			_ = os.Remove(tmp.Name())
		}
	}()
	if _, err = tmp.Write(append(data, '\n')); err != nil {
		return err
	}
	if err = tmp.Sync(); err != nil {
		return err
	}
	if err = tmp.Chmod(0o644); err != nil {
		return err
	}
	if err = tmp.Close(); err != nil {
		return err
	}
	return os.Rename(tmp.Name(), path)
}

// bound enforces the schema's limits so the file always validates: what does not match a
// pattern is left out rather than written.
func (s *factoryStatus) bound() {
	if s.Watcher != nil {
		s.Watcher.Repositories = validRepos(s.Watcher.Repositories)
		s.Watcher.Slots = clampInt(s.Watcher.Slots, 1, 1000)
		s.Watcher.SlotsBusy = clampInt(s.Watcher.SlotsBusy, 0, 1000)
	}
	if c := s.CurrentRun; c != nil {
		if !statusRunIDRe.MatchString(c.RunID) || !validRepo(c.Repository) || c.Issue < 1 {
			s.CurrentRun = nil
		} else {
			if !statusNodeRe.MatchString(c.NodeID) || len(c.NodeID) > maxStatusNodeID {
				c.NodeID = ""
			}
			if c.NodeKind != "agent" && c.NodeKind != "code" {
				c.NodeKind = ""
			}
			if c.Attempt < 1 || c.Attempt > 1000 {
				c.Attempt = 0
			}
		}
	}
	runs := make([]runRecord, 0, len(s.LastRuns))
	for _, r := range s.LastRuns {
		if !statusRunIDRe.MatchString(r.RunID) || !validRepo(r.Repository) || r.Issue < 1 {
			continue
		}
		r.StopDetail = cleanDetail(r.StopDetail)
		if r.Status != startComplete {
			r.Status = startStopped
		}
		if r.Status == startComplete {
			r.StopCode, r.StopDetail = "", ""
		} else {
			r.StopCode = stopCode(r.StopCode)
		}
		r.TotalCostUSD = clampCost(r.TotalCostUSD)
		if r.DurationMS < 0 {
			r.DurationMS = 0
		}
		if r.Retries < 0 {
			r.Retries = 0
		}
		if r.PRNumber < 0 {
			r.PRNumber = 0
		}
		if len(r.RequestModel) > maxStatusModel || !modelRe.MatchString(r.RequestModel) {
			r.RequestModel = ""
		}
		runs = append(runs, r)
		if len(runs) == maxLastRuns {
			break
		}
	}
	s.LastRuns = runs
	queue := make([]queueEntry, 0, len(s.Queue))
	for _, q := range s.Queue {
		if !validRepo(q.Repository) || len(queue) == maxStatusRepos {
			continue
		}
		issues := make([]int, 0, len(q.Issues))
		for _, n := range q.Issues {
			if n >= 1 && n <= math.MaxInt32 && len(issues) < maxQueueIssues {
				issues = append(issues, n)
			}
		}
		queue = append(queue, queueEntry{Repository: q.Repository, Issues: issues})
	}
	s.Queue = queue
	s.Today.TotalCostUSD = clampCost(s.Today.TotalCostUSD)
}

func validRepo(r string) bool { return len(r) <= maxStatusRepo && statusRepoRe.MatchString(r) }

func validRepos(repos []string) []string {
	kept := []string{}
	for _, r := range repos {
		if validRepo(r) && len(kept) < maxStatusRepos {
			kept = append(kept, r)
		}
	}
	return kept
}

func clampInt(v, lo, hi int) int { return max(lo, min(hi, v)) }

func clampCost(v float64) float64 {
	if math.IsNaN(v) || v < 0 {
		return 0
	}
	return math.Round(min(v, maxStatusCost)*1e6) / 1e6
}

func stopCode(reason string) string {
	if statusStopCode[reason] {
		return reason
	}
	return "other"
}

// cleanDetail flattens a stop reason, drops control characters and machine paths and cuts it
// to maxStopDetail runes.
func cleanDetail(s string) string {
	s = strings.Join(strings.Fields(s), " ")
	s = strings.Map(func(r rune) rune {
		if unicode.IsControl(r) {
			return -1
		}
		return r
	}, s)
	s = strings.TrimSpace(scrubPaths(s))
	if r := []rune(s); len(r) > maxStopDetail {
		s = string(r[:maxStopDetail])
	}
	return s
}

// runOutcome is what startIssue knows when a run ends; the rest comes from its receipts.
type runOutcome struct {
	runID, repo        string
	issue              int
	started, finished  time.Time
	complete           bool
	stopReason, detail string // from the runner's stop line, when there was one
	runErr, archiveErr error
	runDir             string // <clone>/odd/runs/<run_id>
}

// buildRunRecord turns a finished run into its allow-listed record.
func buildRunRecord(o runOutcome) runRecord {
	r := runRecord{RunID: o.runID, Repository: o.repo, Issue: o.issue,
		StartedAt: statusTime(o.started), FinishedAt: statusTime(o.finished),
		DurationMS: max(0, o.finished.Sub(o.started).Milliseconds()), Status: startComplete}
	if !o.complete {
		r.Status = startStopped
		switch {
		case o.stopReason != "":
			r.StopCode, r.StopDetail = o.stopReason, o.detail
		case o.runErr != nil:
			r.StopCode, r.StopDetail = "misconfigured", o.runErr.Error()
		case o.archiveErr != nil:
			r.StopCode, r.StopDetail = "archive_failed", o.archiveErr.Error()
		default:
			r.StopCode = "other"
		}
		r.StopCode, r.StopDetail = stopCode(r.StopCode), cleanDetail(r.StopDetail)
	}
	receipts, _ := readReceipts(filepath.Join(o.runDir, "receipts"))
	cost := 0.0
	for _, p := range receipts {
		if p.Telemetry.TotalCostUSD != nil {
			cost += *p.Telemetry.TotalCostUSD
		}
		if p.Step.Attempt > 1 {
			r.Retries++
		}
		if m := p.Telemetry.RequestModel; m != "" && len(m) <= maxStatusModel && modelRe.MatchString(m) {
			r.RequestModel = m
		}
	}
	r.TotalCostUSD = clampCost(cost)
	if m := githubPRURLRe.FindStringSubmatch(findPR(filepath.Join(o.runDir, "logs"))); m != nil {
		r.PRNumber, _ = strconv.Atoi(m[1])
	}
	return r
}

// recordRun removes the current run, prepends the finished one and counts it for today.
func recordRun(path string, out io.Writer, r runRecord) {
	updateStatus(path, out, func(s *factoryStatus) {
		s.CurrentRun = nil
		s.LastRuns = append([]runRecord{r}, s.LastRuns...)
		s.Today.Runs++
		if r.Status == startComplete {
			s.Today.Completed++
		} else {
			s.Today.Stopped++
		}
		s.Today.TotalCostUSD += r.TotalCostUSD
	})
}
