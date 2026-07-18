#!/bin/bash
SKILLS_DIR="$(cd "$(dirname "$0")" && pwd)"
AGENTS_SKILLS_DIR="${HOME}/.agents/skills"
AGENTS_CONFIG_DIR="${HOME}/.config/opencode/agents"

# Link skills
for skill in pyscf-general pyscf-dh; do
    src="$SKILLS_DIR/$skill"
    dst="$AGENTS_SKILLS_DIR/$skill"
    if [ -e "$dst" ]; then
        echo "Skip $skill (already exists at $dst)"
    else
        ln -s "$src" "$dst"
        echo "Linked $dst → $src"
    fi
done

# Link sub-agents
mkdir -p "$AGENTS_CONFIG_DIR"
for agent in "$SKILLS_DIR"/agents/*.md; do
    [ -e "$agent" ] || continue
    name=$(basename "$agent")
    dst="$AGENTS_CONFIG_DIR/$name"
    if [ -e "$dst" ]; then
        echo "Skip $name (already exists at $dst)"
    else
        ln -s "$agent" "$dst"
        echo "Linked $dst → $agent"
    fi
done
