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
    ""
    ".agent-memory/"
    ".github/agents"
    ".github/skills"
    ".guides/"
    "ideas/"
    ".vscode/"
)

# Ensure the target directory exists
mkdir -p "$TARGET_DIR"

# 1. Update or create .gitignore
update_gitignore() {
    local ignore_file="$TARGET_DIR/.gitignore"
    echo "--- Updating .gitignore ---"
    
    # 1. Create file if it doesn't exist
    if [ ! -f "$ignore_file" ]; then
        touch "$ignore_file"
        echo "Created .gitignore"
    else
        # 2. Fix missing newline at end of file if it exists
        # If the last character is not a newline, append one
        if [ -n "$(tail -c 1 "$ignore_file")" ]; then
            echo "" >> "$ignore_file"
        fi
    fi

    # 3. Append entries
    for entry in "${GITIGNORE_ENTRIES[@]}"; do
        if ! grep -qxF "$entry" "$ignore_file"; then
            echo "$entry" >> "$ignore_file"
            echo "Added $entry"
        fi
    done
}

update_gitignore

# 2. Clone repository temporarily
echo "Cloning repository..."
git clone --depth 1 --filter=blob:none --sparse "$REPO_URL" "$TEMP_DIR"
cd "$TEMP_DIR" || exit
git sparse-checkout set "${TARGET_FOLDERS[@]}"
cd ..

# 3. Determine Overwrite Strategy
REPLACE_ALL="n"
EXISTING_FOUND=false

# Check if any of the folders already exist in the target
for folder in "${TARGET_FOLDERS[@]}"; do
    if [ -d "$TARGET_DIR/$folder" ]; then
        EXISTING_FOUND=true
        break
    fi
done

if [ "$EXISTING_FOUND" = true ]; then
    read -p "Existing folders found in $TARGET_DIR. Replace all files? (y/n): " confirm
    [[ "$confirm" == [yY] ]] && REPLACE_ALL="y"
fi

# 4. Sync folders
for folder in "${TARGET_FOLDERS[@]}"; do
    if [ -d "$TEMP_DIR/$folder" ]; then
        echo "Syncing $folder..."
        if [ "$REPLACE_ALL" == "y" ]; then
            # rsync -a: archive mode
            # --delete: (optional) remove files in target that aren't in source
            rsync -ah --progress "$TEMP_DIR/$folder/" "$TARGET_DIR/$folder/"
        else
            # --ignore-existing: Only copy files that don't exist in the target
            rsync -ah --progress --ignore-existing "$TEMP_DIR/$folder/" "$TARGET_DIR/$folder/"
        fi
    fi
done

# Cleanup
rm -rf "$TEMP_DIR"
echo "--- Process Complete ---"
