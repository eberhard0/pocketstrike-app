<!-- Agent Reach by Neo Reid, https://github.com/Panniantong/Agent-Reach, MIT License. This is a PocketStrike-specific guide to the tool as installed in Termux on this phone, not the upstream skill text. -->

# Agent Reach: search and read the internet from Termux

Agent Reach is a read-only command-line tool for searching and reading web content. It is installed
in Termux on this phone. Run it with the `run_in_termux` tool using the full path:

```
~/bin/agent-reach <channel> <action> [args]
~/bin/agent-reach read <url>          # picks the right channel from the link
~/bin/agent-reach channels            # every channel, action and parameter
```

Every command prints one JSON object. `ok: true` puts results in `items`, each with `title`, `url`,
`author`, `published_at` and `text`. `ok: false` has `error.code` and `error.hint`. Give web requests
`timeoutSeconds: 120`. Add `--limit N` to searches to keep the output small.

## What works here without any login

| Need | Command |
|---|---|
| Web search | `~/bin/agent-reach web search "query" --limit 5` |
| Read any page as clean text | `~/bin/agent-reach read https://example.com/article` |
| YouTube search | `~/bin/agent-reach youtube search "query" --limit 5` |
| YouTube video details | `~/bin/agent-reach read https://www.youtube.com/watch?v=ID` |
| YouTube subtitles (transcript) | `~/bin/agent-reach youtube subtitle https://www.youtube.com/watch?v=ID` |
| GitHub repo search | `~/bin/agent-reach github search "query" --limit 5` |
| Read a GitHub repo, issue or PR | `~/bin/agent-reach read https://github.com/owner/repo` |
| Reddit search and posts | `~/bin/agent-reach reddit search "query" --limit 5` |
| LinkedIn public job listings | `~/bin/agent-reach linkedin jobs "role city" --limit 5` |
| V2EX hot topics | `~/bin/agent-reach v2ex hot --limit 5` |

## What does not work on this phone

Twitter/X, Facebook, Instagram, Xiaohongshu, Boss Zhipin and logged-in Reddit or LinkedIn need a
desktop browser that Agent Reach drives, which Android cannot provide. Bilibili needs an extra tool
that is not installed. If a command returns `NEED_SETUP`, `NEED_LOGIN`, `UPSTREAM_BROKEN` or
`PLATFORM_BLOCKED`, say that channel is unavailable on the phone and use web search instead. Do not
run `agent-reach setup`, `add`, `login`, `update` or `uninstall`; those change the installation and
are for the user to decide.

## Working method

1. Search first with a small limit, then `read` the one or two best links for the full text.
2. Search snippets are not the article. Quote or summarise only what a `read` actually returned.
3. For a video, fetch subtitles before summarising; the description alone is not the content.
4. Give the source link for every claim taken from a result, and say when a source could not be read.
5. Never loop on a failing channel: one retry at most, then report it.
