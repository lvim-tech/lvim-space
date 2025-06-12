package main

import (
	"fmt"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"time"
)

func scanDirectory(projectPath, query string, skipDirs []string, maxTime, maxResults, chunkSize int) error {
	// Default values
	if maxTime == 0 {
		maxTime = 10 // 10 seconds default
	}
	if maxResults == 0 {
		maxResults = 1000 // default max results
	}
	if chunkSize == 0 {
		chunkSize = 200 // default chunk size
	}

	var allFiles []FileResult
	currentChunk := make([]FileResult, 0, chunkSize)
	totalCount := 0

	// Default skip directories
	defaultSkipDirs := map[string]bool{
		".git":          true,
		"node_modules":  true,
		".svn":          true,
		".hg":           true,
		"vendor":        true,
		"target":        true,
		"build":         true,
		"dist":          true,
		".next":         true,
		".nuxt":         true,
		"coverage":      true,
		".nyc_output":   true,
		"__pycache__":   true,
		".pytest_cache": true,
		".vscode":       true,
		".idea":         true,
	}

	// Add custom skip dirs
	for _, dir := range skipDirs {
		defaultSkipDirs[dir] = true
	}

	// Timeout handling
	startTime := time.Now()
	maxDuration := time.Duration(maxTime) * time.Second

	err := filepath.Walk(projectPath, func(path string, info os.FileInfo, err error) error {
		if err != nil {
			return nil // Skip errors, continue walking
		}

		// Check timeout
		if time.Since(startTime) > maxDuration {
			return fmt.Errorf("search timeout exceeded")
		}

		// Check max results limit
		if totalCount >= maxResults {
			return fmt.Errorf("max results reached")
		}

		// Skip directories in skip list
		if info.IsDir() {
			if defaultSkipDirs[info.Name()] {
				return filepath.SkipDir
			}
			return nil
		}

		// Skip hidden files and some file types
		if strings.HasPrefix(info.Name(), ".") {
			return nil
		}

		// Skip binary and unwanted file types
		ext := strings.ToLower(filepath.Ext(path))
		skipExtensions := map[string]bool{
			".exe": true, ".dll": true, ".so": true, ".dylib": true,
			".png": true, ".jpg": true, ".jpeg": true, ".gif": true,
			".pdf": true, ".zip": true, ".tar": true, ".gz": true,
			".mp4": true, ".avi": true, ".mov": true, ".mp3": true,
			".obj": true, ".bin": true, ".out": true, ".a": true,
		}

		if skipExtensions[ext] {
			return nil
		}

		// Calculate relative path
		relPath, err := filepath.Rel(projectPath, path)
		if err != nil {
			relPath = path
		}

		// Calculate score based on query match
		score := calculateScore(info.Name(), relPath, query)

		// If query is provided, filter by score
		if query != "" && score == 0 {
			return nil
		}

		fileResult := FileResult{
			Path:         path,
			RelativePath: relPath,
			Name:         info.Name(),
			Score:        score,
		}

		currentChunk = append(currentChunk, fileResult)
		totalCount++

		// Send chunk when it's full
		if len(currentChunk) >= chunkSize {
			allFiles = append(allFiles, currentChunk...)

			// Sort current accumulated files
			sort.Slice(allFiles, func(i, j int) bool {
				return allFiles[i].Score > allFiles[j].Score
			})

			// Send partial response
			response := SearchResponse{
				Files:    allFiles,
				Count:    len(allFiles),
				Partial:  true,
				Complete: false,
			}

			if err := outputJSON(response); err != nil {
				return err
			}

			// Reset chunk but keep accumulated files for sorting
			currentChunk = currentChunk[:0]
		}

		return nil
	})

	// Handle remaining files in the last chunk
	if len(currentChunk) > 0 {
		allFiles = append(allFiles, currentChunk...)
	}

	// Final sort of all files
	sort.Slice(allFiles, func(i, j int) bool {
		return allFiles[i].Score > allFiles[j].Score
	})

	// Send final response
	finalResponse := SearchResponse{
		Files:    allFiles,
		Count:    len(allFiles),
		Partial:  false,
		Complete: true,
	}

	if err != nil {
		finalResponse.Error = err.Error()
	}

	return outputJSON(finalResponse)
}

func calculateScore(fileName, relativePath, query string) float64 {
	if query == "" {
		return 1.0 // No query, all files match
	}

	queryLower := strings.ToLower(query)
	fileNameLower := strings.ToLower(fileName)
	relativePathLower := strings.ToLower(relativePath)

	score := 0.0

	// 1. Exact filename match
	if fileNameLower == queryLower {
		score = 1000.0
	} else if relativePathLower == queryLower {
		// 2. Exact path match
		score = 900.0
	} else if strings.HasPrefix(fileNameLower, queryLower) {
		// 3. Filename starts with query
		score = 800.0
	} else if strings.HasPrefix(relativePathLower, queryLower) {
		// 4. Path starts with query
		score = 700.0
	} else if strings.Contains(fileNameLower, queryLower) {
		// 5. Filename contains query
		score = 600.0
	} else if strings.Contains(relativePathLower, queryLower) {
		// 6. Path contains query
		score = 500.0
	} else {
		// 7. Fuzzy match
		fuzzyScoreName := calculateFuzzyScore(fileNameLower, queryLower)
		fuzzyScorePath := calculateFuzzyScore(relativePathLower, queryLower)

		if fuzzyScoreName > 0 {
			score = 300.0 + fuzzyScoreName
		} else if fuzzyScorePath > 0 {
			score = 200.0 + fuzzyScorePath
		}
	}

	return score
}

func calculateFuzzyScore(text, pattern string) float64 {
	if len(pattern) == 0 {
		return 0
	}

	textLen := len(text)
	patternLen := len(pattern)
	textIdx := 0
	patternIdx := 0
	matches := 0
	consecutiveMatches := 0
	score := 0.0

	// Check if all characters from pattern are found in text in the right order
	for textIdx < textLen && patternIdx < patternLen {
		if text[textIdx] == pattern[patternIdx] {
			matches++
			consecutiveMatches++
			patternIdx++

			// Bonus for consecutive matches
			score += float64(consecutiveMatches) * 2
		} else {
			consecutiveMatches = 0
		}
		textIdx++
	}

	// All pattern characters must be found
	if patternIdx >= patternLen {
		// Bonus for shorter text (more precise match)
		lengthBonus := float64(max(0, 50-textLen))
		// Bonus for match ratio
		matchRatio := float64(matches) / float64(patternLen)
		score += lengthBonus + (matchRatio * 100)
		return score
	}

	return 0 // Not all characters found
}

func max(a, b int) int {
	if a > b {
		return a
	}
	return b
}
