#!/bin/bash
SKILLS_DIR="$(cd "$(dirname "$0")" && pwd)"
AGENTS_DIR="${HOME}/.agents/skills"

for skill in pyscf-general pyscf-dh; do
    src="$SKILLS_DIR/$skill"
    dst="$AGENTS_DIR/$skill"
    if [ -e "$dst" ]; then
        echo "Skip $skill (already exists at $dst)"
    else
        ln -s "$src" "$dst"
        echo "Linked $dst → $src"
    fi
done
