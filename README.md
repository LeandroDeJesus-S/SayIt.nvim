# SayIt 🎙️

This plugin makes Neovim talk to you, bro. You select some text, and it reads it out loud. That's it.

## How it works
It starts a tiny Python server in the background that turns text into speech using kokoro and streams it straight to `mpv` so it starts talking.

> [!NOTE]
> The plugin uses the [kokoro-onnx](https://github.com/thewh1teagle/kokoro-onnx) variation which is optimized to run on CPU.

## You need these
Make sure you have these installed:
- `uv` (to run the Python stuff)
- `curl` (to grab the audio)
- `mpv` (to play the audio)

## Install it
If you use `lazy.nvim`:

```lua
{
    "LeandroDeJesus-S/SayIt.nvim",
    opts = {},
    config = function(_, opts)
        require("sayit").setup(opts)
    end,
}
```

The first time you use it, it will download the voice models (~300MB) automatically.

## How to use it
- `:SayIt` — Reads your selection or the current line.
- `:%SayIt` — Reads the whole file.
- `:ShutUp` — Make it shut up.

### Keymaps
- `<leader>ks` — Speak selection.
- `<leader>kb` — Speak buffer.

## Config stuff

<details>
<summary>Default settings if you want to change them</summary>

```lua
require('sayit').setup({
    server = {
        host = "localhost",
        port = 8000,
    },
    kokoro = {
        voice = "af_bella",
        speed = 1.0,
        lang = "en-us",
        auto_download = true,  -- automatically download the model and voices if they don't exist
        model_url = "https://github.com/thewh1teagle/kokoro-onnx/releases/download/model-files-v1.0/kokoro-v1.0.onnx",
        voices_url = "https://github.com/thewh1teagle/kokoro-onnx/releases/download/model-files-v1.0/voices-v1.0.bin",
        model_path = vim.fn.stdpath("data") .. "/kokoro-v1.0.onnx",-- Path to save kokoro model
        voices_path = vim.fn.stdpath("data") .. "/voices-v1.0.bin",-- Path to save kokoro voices
        -- Limits CPU usage so your fan doesn't explode
        intra_op_threads = 1,
        inter_op_threads = 1,
    },
    keymaps = {
        speak_selection = "<leader>ks",
        speak_buffer = "<leader>kb",
    },
})
```
</details>

## License

[MIT](LICENSE)

---

**PS:** I vibe coded this for myself and only tested it on Linux. It might be buggy, it might eat your RAM, and it definitely needs `uv` and `mpv`. Use it if you want, bro.
