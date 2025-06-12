package main

import (
	"encoding/json"
	"fmt"
	"io"
	"os"
)

func main() {
	// Read JSON from stdin
	input, err := io.ReadAll(os.Stdin)
	if err != nil {
		fmt.Fprintf(os.Stderr, "Error reading stdin: %v\n", err)
		os.Exit(1)
	}

	var request SearchRequest
	if err := json.Unmarshal(input, &request); err != nil {
		fmt.Fprintf(os.Stderr, "Error parsing JSON: %v\n", err)
		os.Exit(1)
	}

	switch request.Action {
	case "scan":
		handleScan(request)
	default:
		fmt.Fprintf(os.Stderr, "Unknown action: %s\n", request.Action)
		os.Exit(1)
	}
}

func handleScan(request SearchRequest) {
	err := scanDirectory(
		request.ProjectPath,
		request.Query,
		request.SkipDirs,
		request.MaxTime,
		request.MaxResults,
		request.ChunkSize,
	)

	if err != nil {
		// Send error response
		response := SearchResponse{
			Files:    []FileResult{},
			Count:    0,
			Complete: true,
			Error:    err.Error(),
		}
		outputJSON(response)
	}
}

func outputJSON(v any) error {
	encoder := json.NewEncoder(os.Stdout)
	encoder.SetIndent("", "  ")
	if err := encoder.Encode(v); err != nil {
		fmt.Fprintf(os.Stderr, "Error encoding JSON: %v\n", err)
		return err
	}
	return nil
}
