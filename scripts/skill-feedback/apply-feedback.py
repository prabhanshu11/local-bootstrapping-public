#!/usr/bin/env python3
"""
apply-feedback.py - Analyze feedback and apply adjustments to skills

This script:
1. Reads pending feedback from SQLite database
2. Matches feedback against adjustment rules
3. Applies changes to SKILL.md files
4. Logs all adjustments for audit

Usage:
    apply-feedback.py analyze              # Show pending feedback and suggested changes
    apply-feedback.py apply [--dry-run]    # Apply changes (or preview with --dry-run)
    apply-feedback.py rules                # List all adjustment rules
    apply-feedback.py add-rule             # Interactive rule creation
"""

import sqlite3
import os
import sys
import re
import argparse
from pathlib import Path
from datetime import datetime
from typing import Optional, List, Dict, Tuple

# Simple YAML parser for skill frontmatter (no external deps)
def simple_yaml_parse(text: str) -> Dict:
    """Parse simple YAML frontmatter without external library."""
    result = {}
    current_key = None
    current_list = None

    for line in text.split('\n'):
        stripped = line.strip()
        if not stripped:
            continue

        # Check for list item
        if line.startswith('  - '):
            if current_list is not None:
                current_list.append(stripped[2:])  # Remove '- '
            continue

        # Check for key: value
        if ':' in stripped:
            key, _, value = stripped.partition(':')
            key = key.strip()
            value = value.strip()

            if value:
                result[key] = value
                current_list = None
            else:
                # Start of a list or multi-line value
                result[key] = []
                current_list = result[key]
                current_key = key

    return result

# Configuration
DB_DIR = Path.home() / ".local/share/skill-feedback"
DB_FILE = DB_DIR / "feedback.db"
SKILLS_DIR = Path.home() / ".claude/skills"
SKILLS_SOURCE_DIR = Path.home() / "Programs/local-bootstrapping/dotfiles/.claude/skills"

class Colors:
    RED = '\033[0;31m'
    GREEN = '\033[0;32m'
    YELLOW = '\033[1;33m'
    BLUE = '\033[0;34m'
    CYAN = '\033[0;36m'
    NC = '\033[0m'

def log_info(msg): print(f"{Colors.BLUE}[INFO]{Colors.NC} {msg}")
def log_success(msg): print(f"{Colors.GREEN}[OK]{Colors.NC} {msg}")
def log_warn(msg): print(f"{Colors.YELLOW}[WARN]{Colors.NC} {msg}")
def log_error(msg): print(f"{Colors.RED}[ERROR]{Colors.NC} {msg}")

class SkillFeedbackAnalyzer:
    def __init__(self, db_path: Path):
        self.db_path = db_path
        self.conn = sqlite3.connect(str(db_path))
        self.conn.row_factory = sqlite3.Row

    def close(self):
        self.conn.close()

    def get_pending_feedback(self) -> List[Dict]:
        """Get feedback that hasn't been applied yet."""
        cursor = self.conn.execute("""
            SELECT f.id, f.skill_name, f.aspect, f.feedback_type, f.feedback_text, f.context, f.created_at
            FROM skill_feedback f
            LEFT JOIN adjustment_log a ON f.id = a.feedback_id
            WHERE a.id IS NULL
            ORDER BY f.created_at ASC
        """)
        return [dict(row) for row in cursor.fetchall()]

    def get_rules(self) -> List[Dict]:
        """Get all enabled adjustment rules."""
        cursor = self.conn.execute("""
            SELECT * FROM adjustment_rules
            WHERE enabled = 1
            ORDER BY priority DESC, aspect, rule_name
        """)
        return [dict(row) for row in cursor.fetchall()]

    def match_rules(self, feedback: Dict) -> List[Dict]:
        """Find rules that match this feedback."""
        rules = self.get_rules()
        matches = []

        for rule in rules:
            if rule['aspect'] != feedback['aspect'] and rule['aspect'] != 'general':
                continue

            # Check if trigger condition matches feedback text
            pattern = rule['trigger_condition']
            if re.search(pattern, feedback['feedback_text'], re.IGNORECASE):
                matches.append(rule)

        return matches

    def parse_skill_frontmatter(self, skill_path: Path) -> Tuple[Dict, str]:
        """Parse SKILL.md frontmatter and body."""
        content = skill_path.read_text()

        # Split frontmatter from body
        match = re.match(r'^---\n(.*?)\n---\n(.*)$', content, re.DOTALL)
        if not match:
            raise ValueError(f"Invalid SKILL.md format: {skill_path}")

        frontmatter_text = match.group(1)
        body = match.group(2)

        # Parse YAML frontmatter (using simple parser)
        frontmatter = simple_yaml_parse(frontmatter_text)

        return frontmatter, body

    def format_skill_content(self, frontmatter: Dict, body: str) -> str:
        """Reconstruct SKILL.md from frontmatter and body."""
        # Format allowed-tools as YAML list
        yaml_lines = ['---']
        for key, value in frontmatter.items():
            if key == 'allowed-tools' and isinstance(value, list):
                yaml_lines.append('allowed-tools:')
                for tool in value:
                    yaml_lines.append(f'  - {tool}')
            elif isinstance(value, str):
                # Handle multi-line descriptions
                if '\n' in value or len(value) > 80:
                    yaml_lines.append(f'{key}: >')
                    for line in value.split('\n'):
                        yaml_lines.append(f'  {line}')
                else:
                    yaml_lines.append(f'{key}: {value}')
            else:
                yaml_lines.append(f'{key}: {value}')
        yaml_lines.append('---')

        return '\n'.join(yaml_lines) + '\n' + body

    def apply_adjustment(self, skill_path: Path, rule: Dict, feedback: Dict, dry_run: bool = False) -> Optional[Dict]:
        """Apply an adjustment rule to a skill."""
        try:
            frontmatter, body = self.parse_skill_frontmatter(skill_path)
        except Exception as e:
            log_error(f"Failed to parse {skill_path}: {e}")
            return None

        old_value = None
        new_value = None
        parameter_name = rule['aspect']

        # Determine what to change based on adjustment type
        adj_type = rule['adjustment_type']
        adj_value = rule['adjustment_value']

        # If adjustment_value is empty, try to extract from feedback
        if not adj_value:
            feedback_text = feedback['feedback_text']

            # Try to extract quoted value from feedback
            quoted = re.search(r"['\"]([^'\"]+)['\"]", feedback_text)
            if quoted:
                adj_value = quoted.group(1)

            # For tool additions: extract tool name
            if not adj_value and adj_type == 'add_tool':
                # Match patterns like "needed Write tool", "need Bash tool"
                tool_match = re.search(r"needed?\s+(\w+)\s+tool", feedback_text, re.IGNORECASE)
                if tool_match:
                    adj_value = tool_match.group(1).capitalize()

            # For keywords: try to extract the action/phrase
            if not adj_value and adj_type == 'add_keyword':
                # Match patterns like "when I said X", "said 'X'", "find X"
                said_match = re.search(r"(?:said|when.*said|asked)\s+['\"]?([^'\"]+)['\"]?$", feedback_text, re.IGNORECASE)
                if said_match:
                    adj_value = said_match.group(1).strip()
                else:
                    # Try to extract after "add" or similar
                    add_match = re.search(r"add\s+['\"]?([^'\"]+)['\"]?\s+(?:as|to|keyword)", feedback_text, re.IGNORECASE)
                    if add_match:
                        adj_value = add_match.group(1).strip()

        if not adj_value:
            log_warn(f"Could not extract adjustment value from feedback")
            return None

        if adj_type == 'add_tool':
            old_value = frontmatter.get('allowed-tools', [])
            if isinstance(old_value, str):
                old_value = [old_value]
            elif old_value is None:
                old_value = []

            if adj_value not in old_value:
                new_value = old_value + [adj_value]
                frontmatter['allowed-tools'] = new_value
            else:
                log_info(f"Tool {adj_value} already in allowed-tools")
                return None

        elif adj_type == 'remove_tool':
            old_value = frontmatter.get('allowed-tools', [])
            if adj_value in old_value:
                new_value = [t for t in old_value if t != adj_value]
                frontmatter['allowed-tools'] = new_value
            else:
                return None

        elif adj_type == 'add_keyword':
            old_value = frontmatter.get('description', '')
            # Add keyword to description
            new_value = f"{old_value} Also use when user mentions '{adj_value}'."
            frontmatter['description'] = new_value
            parameter_name = 'description'

        elif adj_type == 'append':
            if rule['aspect'] == 'description':
                old_value = frontmatter.get('description', '')
                new_value = f"{old_value} {adj_value}"
                frontmatter['description'] = new_value
            elif rule['aspect'] == 'instructions':
                old_value = body
                new_value = body + f"\n\n{adj_value}"
                body = new_value

        elif adj_type == 'prepend':
            if rule['aspect'] == 'description':
                old_value = frontmatter.get('description', '')
                new_value = f"{adj_value} {old_value}"
                frontmatter['description'] = new_value

        elif adj_type == 'replace':
            if rule['aspect'] == 'description':
                old_value = frontmatter.get('description', '')
                new_value = adj_value
                frontmatter['description'] = new_value

        if new_value is None:
            return None

        # Format and write
        new_content = self.format_skill_content(frontmatter, body)

        if dry_run:
            print(f"\n{Colors.CYAN}--- Would modify: {skill_path} ---{Colors.NC}")
            print(f"  Parameter: {parameter_name}")
            print(f"  Old: {old_value}")
            print(f"  New: {new_value}")
        else:
            # Write to source directory (the actual tracked files)
            source_path = SKILLS_SOURCE_DIR / skill_path.parent.name / "SKILL.md"
            if source_path.exists():
                source_path.write_text(new_content)
                log_success(f"Updated: {source_path}")
            else:
                log_warn(f"Source path not found: {source_path}")

        return {
            'skill_name': skill_path.parent.name,  # Get directory name, not SKILL.md
            'parameter_name': parameter_name,
            'old_value': str(old_value),
            'new_value': str(new_value),
            'rule_name': rule['rule_name']
        }

    def log_adjustment(self, change: Dict, feedback_id: int):
        """Log an adjustment to the database."""
        self.conn.execute("""
            INSERT INTO adjustment_log (skill_name, rule_name, parameter_name, old_value, new_value, feedback_id)
            VALUES (?, ?, ?, ?, ?, ?)
        """, (change['skill_name'], change['rule_name'], change['parameter_name'],
              change['old_value'], change['new_value'], feedback_id))
        self.conn.commit()


def analyze_feedback(analyzer: SkillFeedbackAnalyzer):
    """Analyze pending feedback and suggest changes."""
    pending = analyzer.get_pending_feedback()

    if not pending:
        log_info("No pending feedback to analyze")
        return

    print(f"\n{Colors.BLUE}=== Pending Feedback Analysis ==={Colors.NC}\n")

    for feedback in pending:
        print(f"{Colors.YELLOW}Feedback #{feedback['id']}{Colors.NC}")
        print(f"  Skill: {feedback['skill_name']}")
        print(f"  Aspect: {feedback['aspect']}")
        print(f"  Type: {feedback['feedback_type']}")
        print(f"  Text: {feedback['feedback_text']}")

        matches = analyzer.match_rules(feedback)
        if matches:
            print(f"  {Colors.GREEN}Matching rules:{Colors.NC}")
            for rule in matches:
                print(f"    - {rule['rule_name']}: {rule['adjustment_type']} -> {rule['adjustment_value'] or '(extract from feedback)'}")
        else:
            print(f"  {Colors.YELLOW}No matching rules{Colors.NC}")
        print()


def apply_changes(analyzer: SkillFeedbackAnalyzer, dry_run: bool = False):
    """Apply changes based on feedback."""
    pending = analyzer.get_pending_feedback()

    if not pending:
        log_info("No pending feedback to apply")
        return

    mode = "DRY RUN" if dry_run else "APPLY"
    print(f"\n{Colors.BLUE}=== {mode}: Applying Feedback ==={Colors.NC}\n")

    applied_count = 0

    for feedback in pending:
        matches = analyzer.match_rules(feedback)

        if not matches:
            continue

        skill_path = SKILLS_DIR / feedback['skill_name']
        skill_file = skill_path / "SKILL.md"

        if not skill_file.exists():
            log_warn(f"Skill file not found: {skill_file}")
            continue

        for rule in matches:
            change = analyzer.apply_adjustment(skill_file, rule, feedback, dry_run)
            if change and not dry_run:
                analyzer.log_adjustment(change, feedback['id'])
                applied_count += 1

    if dry_run:
        log_info(f"Would apply {applied_count} changes")
    else:
        log_success(f"Applied {applied_count} changes")


def list_rules(analyzer: SkillFeedbackAnalyzer):
    """List all adjustment rules."""
    rules = analyzer.get_rules()

    print(f"\n{Colors.BLUE}=== Adjustment Rules ==={Colors.NC}\n")

    for rule in rules:
        enabled = "✓" if rule['enabled'] else "✗"
        print(f"{Colors.GREEN}{enabled}{Colors.NC} {rule['rule_name']} (priority: {rule['priority']})")
        print(f"    Aspect: {rule['aspect']}")
        print(f"    Trigger: {rule['trigger_condition']}")
        print(f"    Action: {rule['adjustment_type']} -> {rule['adjustment_value'] or '(extract from feedback)'}")
        print()


def add_rule(analyzer: SkillFeedbackAnalyzer):
    """Interactively add a new rule."""
    print(f"\n{Colors.BLUE}=== Add Adjustment Rule ==={Colors.NC}\n")

    rule_name = input("Rule name: ").strip()
    aspect = input("Aspect (description/trigger_keywords/allowed_tools/instructions): ").strip()
    trigger = input("Trigger pattern (regex): ").strip()
    adj_type = input("Adjustment type (append/prepend/replace/add_keyword/remove_keyword/add_tool/remove_tool): ").strip()
    adj_value = input("Adjustment value (or empty to extract from feedback): ").strip()
    priority = int(input("Priority (0-10, higher = first): ").strip() or "5")

    analyzer.conn.execute("""
        INSERT INTO adjustment_rules (rule_name, aspect, trigger_condition, adjustment_type, adjustment_value, priority)
        VALUES (?, ?, ?, ?, ?, ?)
    """, (rule_name, aspect, trigger, adj_type, adj_value, priority))
    analyzer.conn.commit()

    log_success(f"Rule '{rule_name}' added")


def main():
    parser = argparse.ArgumentParser(description="Analyze and apply skill feedback")
    parser.add_argument('command', choices=['analyze', 'apply', 'rules', 'add-rule'],
                        help='Command to run')
    parser.add_argument('--dry-run', action='store_true',
                        help='Preview changes without applying')

    args = parser.parse_args()

    if not DB_FILE.exists():
        log_error(f"Database not found: {DB_FILE}")
        log_info("Run 'skill-feedback.sh init' first")
        sys.exit(1)

    analyzer = SkillFeedbackAnalyzer(DB_FILE)

    try:
        if args.command == 'analyze':
            analyze_feedback(analyzer)
        elif args.command == 'apply':
            apply_changes(analyzer, dry_run=args.dry_run)
        elif args.command == 'rules':
            list_rules(analyzer)
        elif args.command == 'add-rule':
            add_rule(analyzer)
    finally:
        analyzer.close()


if __name__ == '__main__':
    main()
