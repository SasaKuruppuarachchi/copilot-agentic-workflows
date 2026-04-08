#!/bin/bash

# Check if a target directory was provided
if [ -z "$1" ]; then
    echo "Usage: $0 <target_directory>"
    echo "Example: $0 ."
    exit 1
fi

TARGET_DIR="$1"
REPO_URL="https://github.com/SasaKuruppuarachchi/copilot-agentic-workflows.git"
TARGET_FOLDERS=(".github" ".agent-memory")
TEMP_DIR="temp_repo_clone_$(date +%s)"

# Ensure the target directory exists
mkdir -p "$TARGET_DIR"

echo "Checking dependencies..."
if ! command -v git &> /dev/null || ! command -v rsync &> /dev/null; then
    echo "Error: git and rsync are required."
    exit 1
fi

# Create a temporary directory for a sparse clone
echo "Cloning repository temporarily..."
git clone --depth 1 --filter=blob:none --sparse "$REPO_URL" "$TEMP_DIR"
cd "$TEMP_DIR" || exit
git sparse-checkout set "${TARGET_FOLDERS[@]}"
cd ..

# Loop through the folders and sync them
for folder in "${TARGET_FOLDERS[@]}"; do
    if [ -d "$TEMP_DIR/$folder" ]; then
        echo "--- Processing $folder -> $TARGET_DIR/$folder ---"
        
        # rsync flags:
        # -a: archive (preserve permissions/timestamps)
        # -v: verbose
        # -h: human-readable
        # --ignore-existing: skip files that already exist in the target
        # To handle "ask and replace", we use a loop with 'cp -i' for granular control
        # or rsync's update flag. Here we use rsync for the merge, then 
        # interactive copy for the actual file placement to ensure it prompts you.
        
        cp -ri "$TEMP_DIR/$folder" "$TARGET_DIR/"
    else
        echo "Warning: Folder $folder not found in the repository."
    fi
done

# Cleanup
echo "Cleaning up temporary files..."
rm -rf "$TEMP_DIR"

echo "Success: Folders merged into $TARGET_DIR"
