#!/bin/bash
# terminal-reset.sh - Fix terminal state after Claude Code exits improperly
#
# Claude Code uses advanced terminal features (mouse tracking, kitty keyboard
# protocol, focus reporting) but sometimes doesn't reset them on exit.
# This causes: mouse capture, unprocessed escape sequences like ";129u"

# Reset terminal state on each prompt
_reset_terminal_modes() {
    # Disable mouse tracking modes
    printf '\e[?1000l'  # Disable mouse click tracking
    printf '\e[?1002l'  # Disable mouse drag tracking
    printf '\e[?1003l'  # Disable all mouse tracking
    printf '\e[?1006l'  # Disable SGR mouse mode

    # Disable focus reporting (fixes [I [O sequences)
    printf '\e[?1004l'

    # Reset kitty keyboard protocol (fixes ;129u sequences)
    printf '\e[>0u'

    # Reset bracketed paste mode
    printf '\e[?2004l'
}

# Run on every prompt
PROMPT_COMMAND="_reset_terminal_modes${PROMPT_COMMAND:+;$PROMPT_COMMAND}"
