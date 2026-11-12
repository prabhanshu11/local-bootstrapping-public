-- Skill Feedback System Schema
-- Database: ~/.local/share/skill-feedback/feedback.db

-- Feedback entries from users
CREATE TABLE IF NOT EXISTS skill_feedback (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    skill_name TEXT NOT NULL,
    aspect TEXT NOT NULL,  -- 'description', 'trigger_keywords', 'allowed_tools', 'instructions', 'examples'
    feedback_type TEXT NOT NULL CHECK (feedback_type IN ('positive', 'negative', 'suggestion')),
    feedback_text TEXT NOT NULL,
    context TEXT,  -- Optional: what was the user trying to do
    created_at DATETIME DEFAULT CURRENT_TIMESTAMP
);

-- Skill parameters that can be adjusted (extracted from SKILL.md frontmatter and content)
CREATE TABLE IF NOT EXISTS skill_parameters (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    skill_name TEXT NOT NULL,
    parameter_name TEXT NOT NULL,  -- 'description', 'allowed_tools', 'trigger_keyword_N', etc.
    current_value TEXT NOT NULL,
    previous_value TEXT,
    updated_at DATETIME DEFAULT CURRENT_TIMESTAMP,
    UNIQUE(skill_name, parameter_name)
);

-- Adjustment rules: when feedback matches condition, apply adjustment
CREATE TABLE IF NOT EXISTS adjustment_rules (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    rule_name TEXT NOT NULL UNIQUE,
    aspect TEXT NOT NULL,  -- which aspect this rule applies to
    trigger_condition TEXT NOT NULL,  -- SQL pattern or keyword to match in feedback
    adjustment_type TEXT NOT NULL CHECK (adjustment_type IN ('append', 'prepend', 'replace', 'add_keyword', 'remove_keyword', 'add_tool', 'remove_tool')),
    adjustment_value TEXT NOT NULL,  -- what to add/remove/replace
    priority INTEGER DEFAULT 0,  -- higher priority rules applied first
    enabled INTEGER DEFAULT 1,
    created_at DATETIME DEFAULT CURRENT_TIMESTAMP
);

-- Log of adjustments made (for audit and rollback)
CREATE TABLE IF NOT EXISTS adjustment_log (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    skill_name TEXT NOT NULL,
    rule_name TEXT,
    parameter_name TEXT NOT NULL,
    old_value TEXT,
    new_value TEXT,
    feedback_id INTEGER,  -- which feedback triggered this (if any)
    applied_at DATETIME DEFAULT CURRENT_TIMESTAMP,
    FOREIGN KEY (feedback_id) REFERENCES skill_feedback(id)
);

-- Pre-populate with default adjustment rules
INSERT OR IGNORE INTO adjustment_rules (rule_name, aspect, trigger_condition, adjustment_type, adjustment_value, priority) VALUES
    -- Description improvements
    ('add_trigger_keyword', 'description', 'should trigger when', 'add_keyword', '', 5),
    ('improve_clarity', 'description', 'unclear|confusing', 'replace', '', 3),

    -- Tool access adjustments
    ('add_bash_tool', 'allowed_tools', 'need bash|need shell|command access', 'add_tool', 'Bash', 5),
    ('add_read_tool', 'allowed_tools', 'need to read|file access', 'add_tool', 'Read', 5),
    ('add_edit_tool', 'allowed_tools', 'need to edit|modify files', 'add_tool', 'Edit', 5),
    ('add_write_tool', 'allowed_tools', 'need to write|create files', 'add_tool', 'Write', 5),
    ('add_grep_tool', 'allowed_tools', 'need to search|search files', 'add_tool', 'Grep', 5),

    -- Common feedback patterns
    ('skill_not_triggering', 'trigger_keywords', 'not triggering|did not activate|should have used', 'add_keyword', '', 10),
    ('missing_example', 'instructions', 'need example|show example|how to use', 'append', '', 2);

-- Index for faster queries
CREATE INDEX IF NOT EXISTS idx_feedback_skill ON skill_feedback(skill_name);
CREATE INDEX IF NOT EXISTS idx_feedback_created ON skill_feedback(created_at);
CREATE INDEX IF NOT EXISTS idx_params_skill ON skill_parameters(skill_name);
CREATE INDEX IF NOT EXISTS idx_log_skill ON adjustment_log(skill_name);
