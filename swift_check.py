import subprocess
import os

file_path = "MacDownloadManager/Core/Aria2/Aria2ProcessManager.swift"
with open(file_path, 'r') as f:
    code = f.read()

# Prompt to verify syntax and logic
prompt = f"""
I am an AI assistant helping a developer. I've refactored a Swift file but I'm on a Linux machine and cannot run `swiftc` to compile it.
Can you perform a static analysis of this Swift code? 
Check for:
1. Syntax errors.
2. Logical flaws in the PID file handling.
3. Compatibility with macOS APIs used (Process, FileManager, Darwin).

File content:
```swift
{code}
```
"""

# Use gh models to ask GPT-4o for a review
process = subprocess.Popen(['gh', 'models', 'run', 'openai/gpt-4o'], stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
stdout, stderr = process.communicate(input=prompt)

print(stdout)
