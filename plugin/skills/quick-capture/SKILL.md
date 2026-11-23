---
name: quick-capture
description: Retrieve the latest macOS screenshot captured with Antigravity Quick Entry when the user asks you to look at their last screenshot or screen capture.
---
# Quick Capture Skill

When the user refers to "my last screenshot", "my latest capture", or "what I just captured with Quick Entry", call the `get_latest_screenshot` MCP tool from the `quick-capture` server to inspect the captured PNG image and its window metadata.
