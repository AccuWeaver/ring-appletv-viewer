#!/usr/bin/env bash
#
# One-time project setup: configures git hooks and verifies tooling.

set -euo pipefail

echo "🔧 Setting up development environment..."

# Point git to the project hooks directory
git config core.hooksPath .githooks
echo "✅ Git hooks configured (.githooks/pre-commit)"

# Check for SwiftLint
if command -v swiftlint &> /dev/null; then
    echo "✅ SwiftLint found: $(swiftlint version)"
else
    echo "⚠️  SwiftLint not found. Install with: brew install swiftlint"
fi

echo "🎉 Setup complete."
