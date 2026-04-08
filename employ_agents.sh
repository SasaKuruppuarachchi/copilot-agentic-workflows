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

# Patterns to add to .gitignore
GITIGNORE_ENTRIES=(
    ".agent-memory/"
    ".github/agents"
    ".github/skills"
    "ideas/"
    ".vscode/"
)

# Ensure the target directory exists
mkdir -p "$TARGET_DIR"

echo "Checking dependencies..."
if ! command -v git &> /dev/null || ! command -v rsync &> /dev/null; then
    echo "Error: git and rsync are required."
    exit 1
fi

# Function to update or create .gitignore
update_gitignore() {
    local ignore_file="$TARGET_DIR/.gitignore"
    echo "--- Updating .gitignore in $TARGET_DIR ---"
    
    # Create file if it doesn't exist
    if [ ! -f "$ignore_file" ]; then
        touch "$ignore_file"
        echo "Created new .gitignore file."
    fi

    for entry in "${GITIGNORE_ENTRIES[@]}"; do
        # Check if entry already exists to avoid duplicates
        if ! grep -qxF "$entry" "$ignore_file"; then
            echo "$entry" >> "$ignore_file"
            echo "Added $entry to .gitignore"
        else
            echo "Entry $entry already exists, skipping."
        fi
    done
}

# 1. Handle .gitignore first
update_gitignore

# 2. Create a temporary directory for a sparse clone
echo "Cloning repository temporarily..."
git clone --depth 1 --filter=blob:none --sparse "$REPO_URL" "$TEMP_DIR"
cd "$TEMP_DIR" || exit
git sparse-checkout set "${TARGET_FOLDERS[@]}"
cd ..

# 3. Loop through the folders and sync them
for folder in "${TARGET_FOLDERS[@]}"; do
    if [ -d "$TEMP_DIR/$folder" ]; then
        echo "--- Processing $folder -> $TARGET_DIR/$folder ---"
        
        # -r: recursive
        # -i: interactive (will ask before overwriting files)
        cp -ri "$TEMP_DIR/$folder" "$TARGET_DIR/"
    else
        echo "Warning: Folder $folder not found in the repository."
    fi
done

# Cleanup
echo "Cleaning up temporary files..."
rm -rf "$TEMP_DIR"

echo "Success: Folders merged and .gitignore updated in $TARGET_DIR"