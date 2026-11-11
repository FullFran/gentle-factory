// Package catalog builds and checks the HCS-0001 catalog manifest of the factory's own
// distributable parts. Slice 1 has one entry: the pipeline embedded in the binary.
package catalog

import (
	"archive/tar"
	"bytes"
	"compress/gzip"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"regexp"
	"sort"
	"strings"
	"time"

	"github.com/FullFran/gentle-factory/pipeline"
)

// Paths of the catalog files, relative to the repository root.
const (
	SourcePath  = "catalog/source.json"
	CatalogPath = "catalog/catalog.json"
)

// HCSVersion is the hcsVersion declared by instance documents (HCS v0.1.0-draft.7).
const HCSVersion = "0.1"

// MediaType of the pipeline package bytes.
const MediaType = "application/vnd.oci.image.layer.v1.tar+gzip"

// Source is the hand-written catalog identity in catalog/source.json.
type Source struct {
	ID      string `json:"id"`
	Version string `json:"version"`
}

// Catalog is an HCS-0001 catalog manifest.
type Catalog struct {
	HCSVersion string  `json:"hcsVersion"`
	ID         string  `json:"id"`
	Version    string  `json:"version"`
	Entries    []Entry `json:"entries"`
}

// Entry is one package of a catalog manifest.
type Entry struct {
	ID            string         `json:"id"`
	Version       string         `json:"version"`
	ContentHash   string         `json:"contentHash"`
	ContentID     string         `json:"contentId"`
	Size          int64          `json:"size"`
	MediaType     string         `json:"mediaType"`
	Contributions []Contribution `json:"contributions"`
}

// Contribution is one member of a package.
type Contribution struct {
	Kind string `json:"kind"`
	Path string `json:"path"`
}

// Archive returns the deterministic package of the embedded pipeline: the gzip bytes,
// the uncompressed tar stream and the member names in byte order.
func Archive() (tgz, tarball []byte, names []string, err error) {
	dir, err := os.MkdirTemp("", "gentle-factory-catalog-")
	if err != nil {
		return nil, nil, nil, err
	}
	defer os.RemoveAll(dir)
	if _, err := pipeline.Materialize(dir); err != nil {
		return nil, nil, nil, err
	}
	des, err := os.ReadDir(dir)
	if err != nil {
		return nil, nil, nil, err
	}
	for _, de := range des {
		if de.Type().IsRegular() {
			names = append(names, de.Name())
		}
	}
	sort.Strings(names)
	var tb bytes.Buffer
	tw := tar.NewWriter(&tb)
	for _, name := range names {
		data, err := os.ReadFile(filepath.Join(dir, name))
		if err != nil {
			return nil, nil, nil, err
		}
		mode := int64(0o644)
		if strings.HasSuffix(name, ".sh") {
			mode = 0o755
		}
		hdr := &tar.Header{
			Typeflag: tar.TypeReg,
			Name:     name,
			Mode:     mode,
			Size:     int64(len(data)),
			ModTime:  time.Unix(0, 0),
			Format:   tar.FormatUSTAR,
		}
		if err := tw.WriteHeader(hdr); err != nil {
			return nil, nil, nil, err
		}
		if _, err := tw.Write(data); err != nil {
			return nil, nil, nil, err
		}
	}
	if err := tw.Close(); err != nil {
		return nil, nil, nil, err
	}
	var gb bytes.Buffer
	zw, err := gzip.NewWriterLevel(&gb, gzip.BestCompression)
	if err != nil {
		return nil, nil, nil, err
	}
	if _, err := zw.Write(tb.Bytes()); err != nil {
		return nil, nil, nil, err
	}
	if err := zw.Close(); err != nil {
		return nil, nil, nil, err
	}
	return gb.Bytes(), tb.Bytes(), names, nil
}

func digest(b []byte) string {
	sum := sha256.Sum256(b)
	return "sha256:" + hex.EncodeToString(sum[:])
}

func kind(name string) string {
	switch {
	case name == pipeline.SpecName:
		return "x-gentle-factory-spec"
	case strings.HasSuffix(name, ".sh"):
		return "x-gentle-factory-node"
	default:
		return "x-gentle-factory-prompt"
	}
}

// ReadSource reads catalog/source.json under root.
func ReadSource(root string) (Source, error) {
	var src Source
	data, err := os.ReadFile(filepath.Join(root, SourcePath))
	if err != nil {
		return src, err
	}
	dec := json.NewDecoder(bytes.NewReader(data))
	dec.DisallowUnknownFields()
	if err := dec.Decode(&src); err != nil {
		return src, fmt.Errorf("%s: %w", SourcePath, err)
	}
	return src, nil
}

// Build returns the catalog for src and the package bytes of its pipeline entry.
func Build(src Source) (Catalog, []byte, error) {
	tgz, tarball, names, err := Archive()
	if err != nil {
		return Catalog{}, nil, err
	}
	contribs := make([]Contribution, 0, len(names))
	for _, n := range names {
		contribs = append(contribs, Contribution{Kind: kind(n), Path: n})
	}
	entries := []Entry{{
		ID:            src.ID + ".pipeline",
		Version:       src.Version,
		ContentHash:   digest(tgz),
		ContentID:     digest(tarball),
		Size:          int64(len(tgz)),
		MediaType:     MediaType,
		Contributions: contribs,
	}}
	sort.Slice(entries, func(i, j int) bool { return entries[i].ID < entries[j].ID })
	return Catalog{HCSVersion: HCSVersion, ID: src.ID, Version: src.Version, Entries: entries}, tgz, nil
}

// Marshal renders c as committed: two-space indent, no HTML escaping, trailing newline.
func Marshal(c Catalog) ([]byte, error) {
	var b bytes.Buffer
	enc := json.NewEncoder(&b)
	enc.SetEscapeHTML(false)
	enc.SetIndent("", "  ")
	if err := enc.Encode(c); err != nil {
		return nil, err
	}
	return b.Bytes(), nil
}

var (
	dottedID   = regexp.MustCompile(`^[a-z0-9]([a-z0-9-]*[a-z0-9])?(\.[a-z0-9]([a-z0-9-]*[a-z0-9])?)+$`)
	versionRe  = regexp.MustCompile(`^[^\s]+$`)
	digestRe   = regexp.MustCompile(`^(sha256:[a-f0-9]{64}|sha512:[a-f0-9]{128})$`)
	kindRe     = regexp.MustCompile(`^(skill|mcp-server|x-[a-z0-9]+(-[a-z0-9]+)*)$`)
	docKeys    = []string{"hcsVersion", "id", "version", "entries"}
	entryKeys  = []string{"id", "version", "contentHash", "contentId", "size", "mediaType", "contributions"}
	contribKey = []string{"kind", "path"}
)

func members(where string, raw map[string]json.RawMessage, allowed []string) []string {
	var probs []string
	for k := range raw {
		found := false
		for _, a := range allowed {
			found = found || k == a
		}
		if !found {
			probs = append(probs, fmt.Sprintf("%s: unexpected member %q", where, k))
		}
	}
	for _, a := range allowed {
		if _, ok := raw[a]; !ok {
			probs = append(probs, fmt.Sprintf("%s: missing member %q", where, a))
		}
	}
	sort.Strings(probs)
	return probs
}

func validID(s string) bool      { return len(s) <= 128 && dottedID.MatchString(s) }
func validVersion(s string) bool { return len(s) <= 128 && versionRe.MatchString(s) }

func validPath(p string) bool {
	if p == "" || strings.HasPrefix(p, "/") || strings.Contains(p, `\`) {
		return false
	}
	for _, seg := range strings.Split(p, "/") {
		if seg == ".." || seg == "" {
			return false
		}
	}
	return true
}

// Validate enforces the HCS-0001 rules slice 1 checks by hand on a catalog document.
func Validate(data []byte) (Catalog, []string) {
	var c Catalog
	var probs []string
	var doc map[string]json.RawMessage
	if err := json.Unmarshal(data, &doc); err != nil {
		return c, []string{fmt.Sprintf("%s: invalid JSON: %v", CatalogPath, err)}
	}
	probs = append(probs, members(CatalogPath, doc, docKeys)...)
	var rawEntries []map[string]json.RawMessage
	if err := json.Unmarshal(doc["entries"], &rawEntries); err != nil {
		probs = append(probs, fmt.Sprintf("%s: entries is not an array of objects", CatalogPath))
	}
	for i, e := range rawEntries {
		where := fmt.Sprintf("%s: entries[%d]", CatalogPath, i)
		probs = append(probs, members(where, e, entryKeys)...)
		var rawContribs []map[string]json.RawMessage
		if err := json.Unmarshal(e["contributions"], &rawContribs); err == nil {
			for j, rc := range rawContribs {
				probs = append(probs, members(fmt.Sprintf("%s.contributions[%d]", where, j), rc, contribKey)...)
			}
		}
	}
	dec := json.NewDecoder(bytes.NewReader(data))
	dec.DisallowUnknownFields()
	if err := dec.Decode(&c); err != nil {
		return c, append(probs, fmt.Sprintf("%s: %v", CatalogPath, err))
	}
	if c.HCSVersion != HCSVersion {
		probs = append(probs, fmt.Sprintf("%s: hcsVersion is %q, want %q", CatalogPath, c.HCSVersion, HCSVersion))
	}
	if !validID(c.ID) {
		probs = append(probs, fmt.Sprintf("%s: id %q is not a dotted id", CatalogPath, c.ID))
	}
	if !validVersion(c.Version) {
		probs = append(probs, fmt.Sprintf("%s: version %q is not a valid version", CatalogPath, c.Version))
	}
	seen := map[string]bool{}
	for i, e := range c.Entries {
		where := fmt.Sprintf("%s: entries[%d]", CatalogPath, i)
		if seen[e.ID] {
			probs = append(probs, fmt.Sprintf("%s: duplicate id %q (HCS-0001-R003)", where, e.ID))
		}
		seen[e.ID] = true
		if !validID(e.ID) {
			probs = append(probs, fmt.Sprintf("%s: id %q is not a dotted id", where, e.ID))
		}
		if !validVersion(e.Version) {
			probs = append(probs, fmt.Sprintf("%s: version %q is not a valid version", where, e.Version))
		}
		if !digestRe.MatchString(e.ContentHash) {
			probs = append(probs, fmt.Sprintf("%s: contentHash %q is malformed (HCS-0001-R004)", where, e.ContentHash))
		}
		if !digestRe.MatchString(e.ContentID) {
			probs = append(probs, fmt.Sprintf("%s: contentId %q is malformed (HCS-0001-R017)", where, e.ContentID))
		}
		if e.Size < 0 {
			probs = append(probs, fmt.Sprintf("%s: size %d is negative", where, e.Size))
		}
		if e.MediaType == "" {
			probs = append(probs, fmt.Sprintf("%s: mediaType is missing (HCS-0001-R011)", where))
		}
		if len(e.Contributions) == 0 {
			probs = append(probs, fmt.Sprintf("%s: contributions is empty", where))
		}
		for j, ct := range e.Contributions {
			if !validPath(ct.Path) {
				probs = append(probs, fmt.Sprintf("%s.contributions[%d]: path %q is not a relative / path without .. (HCS-0001-R005)", where, j, ct.Path))
			}
			if !kindRe.MatchString(ct.Kind) {
				probs = append(probs, fmt.Sprintf("%s.contributions[%d]: kind %q is invalid (HCS-0001-R006)", where, j, ct.Kind))
			}
		}
	}
	return c, probs
}

// Check compares the committed catalog under root with an in-memory rebuild and
// returns one line per problem; no problems means the catalog is up to date.
//
// contentId (the sha256 of the uncompressed tar) does not depend on the compressor, so a
// difference in it is a problem. contentHash and size are of the gzip bytes, which depend
// on the Go toolchain's compress/gzip: when only they differ and contentId matches, the
// content is the same and the difference is reported as a warning, not a problem.
func Check(root string) (probs, warnings []string) {
	src, err := ReadSource(root)
	if err != nil {
		return []string{err.Error()}, nil
	}
	data, err := os.ReadFile(filepath.Join(root, CatalogPath))
	if err != nil {
		return []string{err.Error()}, nil
	}
	got, probs := Validate(data)
	want, _, err := Build(src)
	if err != nil {
		return append(probs, err.Error()), nil
	}
	if got.ID != src.ID {
		probs = append(probs, fmt.Sprintf("%s: id is %q, %s says %q", CatalogPath, got.ID, SourcePath, src.ID))
	}
	if got.Version != src.Version {
		probs = append(probs, fmt.Sprintf("%s: version is %q, %s says %q", CatalogPath, got.Version, SourcePath, src.Version))
	}
	if len(got.Entries) != len(want.Entries) {
		probs = append(probs, fmt.Sprintf("%s: %d entries, the rebuild has %d", CatalogPath, len(got.Entries), len(want.Entries)))
	}
	for i := 0; i < len(got.Entries) && i < len(want.Entries); i++ {
		g, w := got.Entries[i], want.Entries[i]
		where := fmt.Sprintf("%s: entries[%d]", CatalogPath, i)
		diff := func(field string, gv, wv any) {
			probs = append(probs, fmt.Sprintf("%s: %s is %v, the rebuild has %v", where, field, gv, wv))
		}
		if g.ID != w.ID {
			diff("id", g.ID, w.ID)
		}
		if g.Version != w.Version {
			diff("version", g.Version, w.Version)
		}
		if g.ContentID != w.ContentID {
			diff("contentId", g.ContentID, w.ContentID)
			if g.ContentHash != w.ContentHash {
				diff("contentHash", g.ContentHash, w.ContentHash)
			}
			if g.Size != w.Size {
				diff("size", g.Size, w.Size)
			}
		} else if g.ContentHash != w.ContentHash || g.Size != w.Size {
			warnings = append(warnings, fmt.Sprintf("%s: same contentId, but contentHash %s size %d differ from this toolchain's gzip (%s, %d)",
				where, g.ContentHash, g.Size, w.ContentHash, w.Size))
		}
		if g.MediaType != w.MediaType {
			diff("mediaType", g.MediaType, w.MediaType)
		}
		if fmt.Sprint(g.Contributions) != fmt.Sprint(w.Contributions) {
			diff("contributions", g.Contributions, w.Contributions)
		}
	}
	if len(probs) > 0 {
		probs = append(probs, "run: go run ./cmd/catalog build")
	}
	return probs, warnings
}
