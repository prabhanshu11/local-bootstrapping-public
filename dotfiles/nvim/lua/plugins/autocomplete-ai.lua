-- AI autocomplete (OpenRouter), plugin repo: ~/Programs/autocomplete-plugin
--
-- Insert mode:  Ctrl+Space  ask for three suggestions (short / medium / long) at the cursor
--   while ghost text is showing:  Tab accept · <leader>h / <leader>l shorter / longer ·
--   <leader>1 / 2 / 3 pick a length · <leader>m change model · Ctrl+E dismiss · typing dismisses
-- Normal mode:  <leader>am  model picker (:AiModel, :AiModelBrowse for every OpenRouter model)
-- API key: $OPENROUTER_API_KEY, else `pass show api/openrouter/nvim_autocomplete`. Failures are one quiet warning.
return {
  {
    dir = vim.fn.expand("~/Programs/autocomplete-plugin"),
    name = "autocomplete-ai",
    event = "InsertEnter",
    keys = { { "<leader>am", "<cmd>AiModel<cr>", desc = "AI autocomplete: pick model" } },
    opts = {
      model = "anthropic/claude-haiku-5.5", -- overridden by the last pick (stdpath("data")/autocomplete-model)
    },
    config = function(_, opts)
      require("autocomplete").setup(opts)
    end,
  },
  -- blink.cmp binds <C-space> ("show") buffer-locally, which shadows a global insert map.
  -- Route the key through blink's keymap so Ctrl+Space asks the AI instead (2026-11-11).
  {
    "saghen/blink.cmp",
    optional = true,
    opts = {
      keymap = {
        ["<C-space>"] = {
          function()
            require("autocomplete").trigger()
            return true
          end,
        },
      },
    },
  },
}
