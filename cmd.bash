agents-assemble() {
    local TARGET_DIR="${1:-.}"
    local URL="https://raw.githubusercontent.com/SasaKuruppuarachchi/copilot-agentic-workflows/main/employ_agents.sh"
    local TIMESTAMP=$(date +%s)
    
    echo "Fetching latest script version..."
    
    curl -fsSL -H "Cache-Control: no-cache" "${URL}?${TIMESTAMP}" -o employ_agents.sh && \
    chmod +x employ_agents.sh && \
    ./employ_agents.sh "$TARGET_DIR" && \
    rm employ_agents.sh
}


agents-assemble