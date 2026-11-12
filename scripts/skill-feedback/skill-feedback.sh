#!/bin/bash
# skill-feedback.sh - CLI for collecting skill feedback
#
# Usage:
#   skill-feedback add <skill-name> <aspect> <type> "<feedback>"
#   skill-feedback list [skill-name]
#   skill-feedback stats
#   skill-feedback init
#
# Examples:
#   skill-feedback add conversation-recall description suggestion "add 'history search' as trigger keyword"
#   skill-feedback add better-screenshot allowed_tools negative "needed Glob tool but it wasn't allowed"
#   skill-feedback list
#   skill-feedback list conversation-recall

set -euo pipefail

DB_DIR="${HOME}/.local/share/skill-feedback"
DB_FILE="${DB_DIR}/feedback.db"
SCHEMA_FILE="$(dirname "$0")/schema.sql"
SKILLS_DIR="${HOME}/.claude/skills"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

log_info() { echo -e "${BLUE}[INFO]${NC} $1"; }
log_success() { echo -e "${GREEN}[OK]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }

# Initialize database
init_db() {
    if [[ ! -d "$DB_DIR" ]]; then
        mkdir -p "$DB_DIR"
        log_info "Created directory: $DB_DIR"
    fi

    if [[ ! -f "$SCHEMA_FILE" ]]; then
        log_error "Schema file not found: $SCHEMA_FILE"
        exit 1
    fi

    sqlite3 "$DB_FILE" < "$SCHEMA_FILE"
    log_success "Database initialized: $DB_FILE"

    # Sync current skill parameters
    sync_skill_params
}

# Sync current skill parameters to database
sync_skill_params() {
    log_info "Syncing skill parameters..."

    for skill_dir in "$SKILLS_DIR"/*/; do
        if [[ -f "${skill_dir}SKILL.md" ]]; then
            skill_name=$(basename "$skill_dir")
            skill_file="${skill_dir}SKILL.md"

            # Extract frontmatter using awk
            description=$(awk '/^---$/{p++} p==1 && /^description:/{gsub(/^description: */, ""); print; exit}' "$skill_file")
            allowed_tools=$(awk '/^---$/{p++} p==1 && /^allowed-tools:/,/^[a-z]/{if(/^  - /) print}' "$skill_file" | tr '\n' ',' | sed 's/  - //g; s/,$//')

            # Upsert parameters
            sqlite3 "$DB_FILE" <<EOF
INSERT INTO skill_parameters (skill_name, parameter_name, current_value)
VALUES ('$skill_name', 'description', '$(echo "$description" | sed "s/'/''/g")')
ON CONFLICT(skill_name, parameter_name)
DO UPDATE SET current_value = excluded.current_value, previous_value = current_value, updated_at = CURRENT_TIMESTAMP;

INSERT INTO skill_parameters (skill_name, parameter_name, current_value)
VALUES ('$skill_name', 'allowed_tools', '$(echo "$allowed_tools" | sed "s/'/''/g")')
ON CONFLICT(skill_name, parameter_name)
DO UPDATE SET current_value = excluded.current_value, previous_value = current_value, updated_at = CURRENT_TIMESTAMP;
EOF
            log_info "  Synced: $skill_name"
        fi
    done

    log_success "Skill parameters synced"
}

# Add feedback
add_feedback() {
    local skill_name="$1"
    local aspect="$2"
    local feedback_type="$3"
    local feedback_text="$4"
    local context="${5:-}"

    # Validate skill exists
    if [[ ! -d "${SKILLS_DIR}/${skill_name}" ]]; then
        log_error "Skill not found: $skill_name"
        log_info "Available skills:"
        ls -1 "$SKILLS_DIR" | grep -v README | sed 's/^/  - /'
        exit 1
    fi

    # Validate aspect
    valid_aspects=("description" "trigger_keywords" "allowed_tools" "instructions" "examples" "general")
    if [[ ! " ${valid_aspects[*]} " =~ " ${aspect} " ]]; then
        log_error "Invalid aspect: $aspect"
        log_info "Valid aspects: ${valid_aspects[*]}"
        exit 1
    fi

    # Validate feedback type
    valid_types=("positive" "negative" "suggestion")
    if [[ ! " ${valid_types[*]} " =~ " ${feedback_type} " ]]; then
        log_error "Invalid feedback type: $feedback_type"
        log_info "Valid types: ${valid_types[*]}"
        exit 1
    fi

    # Insert feedback
    sqlite3 "$DB_FILE" <<EOF
INSERT INTO skill_feedback (skill_name, aspect, feedback_type, feedback_text, context)
VALUES ('$skill_name', '$aspect', '$feedback_type', '$(echo "$feedback_text" | sed "s/'/''/g")', '$(echo "$context" | sed "s/'/''/g")');
EOF

    log_success "Feedback added for skill: $skill_name"
    log_info "  Aspect: $aspect"
    log_info "  Type: $feedback_type"
    log_info "  Feedback: $feedback_text"
}

# List feedback
list_feedback() {
    local skill_filter="${1:-}"

    if [[ -n "$skill_filter" ]]; then
        echo -e "\n${BLUE}=== Feedback for: $skill_filter ===${NC}\n"
        sqlite3 -header -column "$DB_FILE" <<EOF
SELECT id, aspect, feedback_type as type, feedback_text as feedback, datetime(created_at, 'localtime') as created
FROM skill_feedback
WHERE skill_name = '$skill_filter'
ORDER BY created_at DESC
LIMIT 20;
EOF
    else
        echo -e "\n${BLUE}=== All Feedback ===${NC}\n"
        sqlite3 -header -column "$DB_FILE" <<EOF
SELECT id, skill_name as skill, aspect, feedback_type as type, substr(feedback_text, 1, 40) || '...' as feedback, datetime(created_at, 'localtime') as created
FROM skill_feedback
ORDER BY created_at DESC
LIMIT 30;
EOF
    fi
}

# Show statistics
show_stats() {
    echo -e "\n${BLUE}=== Feedback Statistics ===${NC}\n"

    echo "Feedback by Skill:"
    sqlite3 -header -column "$DB_FILE" <<EOF
SELECT skill_name as skill,
       COUNT(*) as total,
       SUM(CASE WHEN feedback_type = 'positive' THEN 1 ELSE 0 END) as positive,
       SUM(CASE WHEN feedback_type = 'negative' THEN 1 ELSE 0 END) as negative,
       SUM(CASE WHEN feedback_type = 'suggestion' THEN 1 ELSE 0 END) as suggestions
FROM skill_feedback
GROUP BY skill_name
ORDER BY total DESC;
EOF

    echo -e "\nFeedback by Aspect:"
    sqlite3 -header -column "$DB_FILE" <<EOF
SELECT aspect, COUNT(*) as count
FROM skill_feedback
GROUP BY aspect
ORDER BY count DESC;
EOF

    echo -e "\nRecent Adjustments:"
    sqlite3 -header -column "$DB_FILE" <<EOF
SELECT skill_name as skill, rule_name, parameter_name as param, datetime(applied_at, 'localtime') as applied
FROM adjustment_log
ORDER BY applied_at DESC
LIMIT 10;
EOF
}

# Show usage
usage() {
    cat <<EOF
Usage: skill-feedback <command> [options]

Commands:
  init                                    Initialize or reset the database
  add <skill> <aspect> <type> "<text>"   Add feedback for a skill
  list [skill]                            List feedback (optionally filter by skill)
  stats                                   Show feedback statistics
  sync                                    Sync current skill parameters to database

Aspects: description, trigger_keywords, allowed_tools, instructions, examples, general
Types: positive, negative, suggestion

Examples:
  skill-feedback init
  skill-feedback add conversation-recall trigger_keywords suggestion "add 'find sessions' keyword"
  skill-feedback add better-screenshot allowed_tools negative "needed Write tool"
  skill-feedback list conversation-recall
  skill-feedback stats

EOF
}

# Ensure database exists
ensure_db() {
    if [[ ! -f "$DB_FILE" ]]; then
        log_warn "Database not found. Initializing..."
        init_db
    fi
}

# Main
main() {
    local cmd="${1:-help}"

    case "$cmd" in
        init)
            init_db
            ;;
        sync)
            ensure_db
            sync_skill_params
            ;;
        add)
            ensure_db
            if [[ $# -lt 5 ]]; then
                log_error "Missing arguments for add command"
                usage
                exit 1
            fi
            add_feedback "$2" "$3" "$4" "$5" "${6:-}"
            ;;
        list)
            ensure_db
            list_feedback "${2:-}"
            ;;
        stats)
            ensure_db
            show_stats
            ;;
        help|--help|-h)
            usage
            ;;
        *)
            log_error "Unknown command: $cmd"
            usage
            exit 1
            ;;
    esac
}

main "$@"
