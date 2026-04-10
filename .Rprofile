source("renv/activate.R")

# Install Git Hooks
local({
  hook_dir <- ".githooks"
  target_dir <- ".git/hooks"

  # Check if we are in a git repository and the hook directory exists
  if (dir.exists(hook_dir) && dir.exists(target_dir)) {
    hooks <- list.files(hook_dir, full.names = TRUE)
    for (hook_source in hooks) {
      hook_name <- basename(hook_source)
      hook_target <- file.path(target_dir, hook_name)
      if (!file.exists(hook_target) || file.mtime(hook_source) > file.mtime(hook_target)) {
        file.copy(hook_source, hook_target, overwrite = TRUE)
        Sys.chmod(hook_target, "0755") # Make it executable
        message(sprintf("Installed Git %s hook.", hook_name))
      }
    }
  }
})
