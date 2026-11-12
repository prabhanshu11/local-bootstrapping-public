---
description: Explore codebase structure using tree -L 2. Use instead of sequential ls commands for understanding project layout.
---

Explore the current directory structure using `tree -L 2 -h` as the primary method.

**Process:**
1. Run `tree -L 2 -h` to get a 2-level overview with file sizes
2. Analyze and explain the project structure based on the output
3. Identify key directories (src/, lib/, components/, etc.)
4. If user specified a path argument, run `tree -L 2 -h <path>` instead

**Depth adjustments (use your judgment):**
- Small projects (<20 files): use `-L 3` or `-L 4`
- Large projects (100+ files): stay at `-L 2`, then focus on specific directories
- Monorepos: use `-L 1 -d` first, then explore specific packages

**Output guidance:**
- Show the tree output
- Provide a brief explanation of the project organization
- Highlight important files/directories
- Suggest which areas to explore further based on the user's likely intent

$ARGUMENTS
