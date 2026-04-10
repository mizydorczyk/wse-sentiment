source("renv/activate.R")

# Install Git Hooks
local({
  hook_source <- ".githooks/commit-msg"
  hook_target <- ".git/hooks/commit-msg"

  # Check if we are in a git repository and the source hook exists
  if (file.exists(hook_source) && dir.exists(".git/hooks")) {
    if (!file.exists(hook_target) || file.mtime(hook_source) > file.mtime(hook_target)) {
      file.copy(hook_source, hook_target, overwrite = TRUE)
      Sys.chmod(hook_target, "0755") # Make it executable
      message("Installed Git commit-msg hook for Conventional Commits.")
    }
  }
})
