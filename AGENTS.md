IRNet is a flutter project with Windows, macOS, Linux, Android, iOS and Web support

To build windows installer we have Inno setup compiler

On Windows, shell commands run in Git Bash: discard output with `/dev/null`, never `nul` (`2>nul` / `>nul` creates a literal `nul` file in the repo that Windows tools can't delete)

