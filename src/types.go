package main

type SearchRequest struct {
	Action      string   `json:"action"`
	ProjectPath string   `json:"project_path"`
	Query       string   `json:"query"`
	SkipDirs    []string `json:"skip_dirs,omitempty"`
	MaxTime     int      `json:"max_time,omitempty"`
	MaxResults  int      `json:"max_results,omitempty"`
	ChunkSize   int      `json:"chunk_size,omitempty"`
}

type FileResult struct {
	Path         string  `json:"path"`
	RelativePath string  `json:"relative_path"`
	Name         string  `json:"name"`
	Score        float64 `json:"score"`
}

type SearchResponse struct {
	Files    []FileResult `json:"files"`
	Count    int          `json:"count"`
	Partial  bool         `json:"partial"`
	Complete bool         `json:"complete"`
	Error    string       `json:"error,omitempty"`
}
