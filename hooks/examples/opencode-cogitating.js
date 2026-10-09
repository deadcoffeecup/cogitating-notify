// ~/.config/opencode/plugins/cogitating.js
export const CogitatingPlugin = async ({ $ }) => ({
  event: async ({ event }) => {
    if (event.type === "session.idle") {
      await $`bash ${process.env.HOME}/.cogitating/cogitating-notify.sh`.quiet().nothrow()
    }
  },
})
