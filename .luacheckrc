std = "lua53"
max_line_length = false
exclude_files = { ".direnv", "tests/tls/.cache", "tests/ocemu/.cache", "tests/ingame/.cache" }

-- Runs under OpenOS, which adds os.sleep.
files["tests/ingame/check.lua"] = { read_globals = { os = { fields = { "sleep" } } } }
