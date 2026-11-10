package runner

import (
	"crypto/sha256"
	"encoding/hex"
	"fmt"
	"io/fs"
	"os"
	"os/exec"
	"path/filepath"
	"sort"
	"strings"
)

func git(repo string, args ...string) (string, error) {
	cmd := exec.Command("git", append([]string{"-C", repo}, args...)...)
	var stderr strings.Builder
	cmd.Stderr = &stderr
	out, err := cmd.Output()
	if err != nil {
		return "", specErr("git %s failed: %s", strings.Join(args, " "), strings.TrimSpace(stderr.String()))
	}
	return string(out), nil
}

func headCommit(repo string) (string, error) {
	out, err := git(repo, "rev-parse", "HEAD")
	return strings.TrimSpace(out), err
}

func sha256Text(text string) string {
	sum := sha256.Sum256([]byte(text))
	return hex.EncodeToString(sum[:])
}

// repoState is HEAD plus every tracked and untracked change, for the read-only guard.
func repoState(repo string) (string, error) {
	head, err := headCommit(repo)
	if err != nil {
		return "", err
	}
	status, err := git(repo, "status", "--porcelain", "--untracked-files=all")
	if err != nil {
		return "", err
	}
	diff, err := git(repo, "diff", "HEAD", "--binary")
	if err != nil {
		return "", err
	}
	untracked, err := git(repo, "ls-files", "--others", "--exclude-standard")
	if err != nil {
		return "", err
	}
	paths := []string{}
	for _, p := range strings.Split(untracked, "\n") {
		if p != "" {
			paths = append(paths, p)
		}
	}
	sort.Strings(paths)
	h := sha256.New()
	for _, p := range paths {
		h.Write([]byte(p + "\x00" + entryDigest(filepath.Join(repo, p))))
	}
	return strings.Join([]string{head, status, sha256Text(diff), hex.EncodeToString(h.Sum(nil))}, "\x00"), nil
}

// pathDigests maps every file, symlink and directory under root/<rel> to a
// content digest. It reads the filesystem, not git, so ignored and untracked
// files count too. Symlinks are recorded by target and never followed.
func pathDigests(root string, rels []string) map[string]string {
	out := map[string]string{}
	for _, rel := range rels {
		top := filepath.Join(root, rel)
		info, err := os.Lstat(top)
		if err != nil {
			continue
		}
		if !info.IsDir() {
			out[rel] = entryDigest(top)
			continue
		}
		_ = filepath.WalkDir(top, func(path string, d fs.DirEntry, err error) error {
			key, _ := filepath.Rel(root, path)
			if err != nil {
				out[key] = "unreadable"
				return nil
			}
			if d.IsDir() {
				out[key+"/"] = "dir"
			} else {
				out[key] = entryDigest(path)
			}
			return nil
		})
	}
	return out
}

func entryDigest(path string) string {
	info, err := os.Lstat(path)
	if err != nil {
		return "missing"
	}
	switch {
	case info.Mode()&os.ModeSymlink != 0:
		target, _ := os.Readlink(path)
		return "link:" + target
	case info.IsDir():
		return "dir"
	}
	data, err := os.ReadFile(path)
	if err != nil {
		return "unreadable"
	}
	sum := sha256.Sum256(data)
	return hex.EncodeToString(sum[:])
}

func changedEntries(before, after map[string]string) []string {
	out := []string{}
	for k, v := range before {
		if after[k] != v {
			out = append(out, k)
		}
	}
	for k := range after {
		if _, ok := before[k]; !ok {
			out = append(out, k)
		}
	}
	sort.Strings(out)
	return out
}

// excludeRunsDir keeps the receipt store out of git status and `git add -A`.
func excludeRunsDir(repo, runsDir string) error {
	rel, err := filepath.Rel(repo, runsDir)
	if err != nil || strings.HasPrefix(rel, "..") {
		return nil
	}
	exclude, err := git(repo, "rev-parse", "--git-path", "info/exclude")
	if err != nil {
		return err
	}
	exclude = strings.TrimSpace(exclude)
	if !filepath.IsAbs(exclude) {
		exclude = filepath.Join(repo, exclude)
	}
	entry := "/" + strings.TrimSuffix(filepath.ToSlash(rel), "/") + "/"
	existing, _ := os.ReadFile(exclude)
	for _, line := range strings.Split(string(existing), "\n") {
		if line == entry {
			return nil
		}
	}
	if err := os.MkdirAll(filepath.Dir(exclude), 0o755); err != nil {
		return err
	}
	f, err := os.OpenFile(exclude, os.O_APPEND|os.O_CREATE|os.O_WRONLY, 0o644)
	if err != nil {
		return err
	}
	defer f.Close()
	prefix := ""
	if len(existing) > 0 && !strings.HasSuffix(string(existing), "\n") {
		prefix = "\n"
	}
	_, err = f.WriteString(prefix + entry + "\n")
	return err
}

// commitProducerChanges closes the node: leftover producer edits become one commit.
func commitProducerChanges(rc *runCtx, node *Node, attempt int) error {
	status, err := git(rc.repo, "status", "--porcelain")
	if err != nil || strings.TrimSpace(status) == "" {
		return err
	}
	if _, err := git(rc.repo, "add", "-A"); err != nil {
		return err
	}
	_, err = git(rc.repo, "-c", "user.name=gentle-factory", "-c", "user.email=factory@localhost",
		"commit", "-q", "--no-verify", "-m", fmt.Sprintf("chore(factory): %s attempt %d (%s)", node.ID, attempt, rc.runID))
	return err
}

// unexpectedPaths lists the paths changed since base (commits, edits and new
// files) that no expected_files entry covers.
func unexpectedPaths(repo, base string, expected []string) ([]string, error) {
	changed, err := git(repo, "diff", "--name-only", "--no-renames", base)
	if err != nil {
		return nil, err
	}
	untracked, err := git(repo, "ls-files", "--others", "--exclude-standard")
	if err != nil {
		return nil, err
	}
	seen := map[string]bool{}
	out := []string{}
	for _, p := range strings.Split(changed+"\n"+untracked, "\n") {
		if p != "" && !seen[p] && !matchExpected(expected, p) {
			seen[p] = true
			out = append(out, p)
		}
	}
	sort.Strings(out)
	return out, nil
}
