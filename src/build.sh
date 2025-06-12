#!/bin/bash
set -e # Exit on any error

# Get script directory and cd to it
script_dir="$(dirname "$0")"
cd "$script_dir" || exit 1

# Build the Go binary
echo "Building lvim-search binary..."
go build -o ../bin/lvim-search . || exit 1

echo "Build completed successfully!"
