# OSINT with GhostTrack via Termux

GhostTrack (HunxByts/GhostTrack) is an open-source OSINT tool: IP geolocation, phone-number
intelligence, and username enumeration across social sites. It is a command-line Python tool, so
it runs inside **Termux** (a Linux environment on this phone), reached with the `run_in_termux`
tool. Use it only for lookups the operator is authorised to perform.

## How to run commands

Every `run_in_termux` call is a fresh non-interactive `bash -lc` shell. It cannot accept keyboard
input, so never launch the tool's interactive menu (`python GhostTR.py`) — it will hang. Always use
the non-interactive wrapper described below. Chain steps with `&&`; raise `timeoutSeconds` for
installs.

## 1. Make sure it is installed

Run this first. It installs Termux packages and GhostTrack only if they are missing, then confirms:

```
pkg install -y git python >/dev/null 2>&1; \
pip install -q requests phonenumbers >/dev/null 2>&1; \
[ -d ~/GhostTrack ] || git clone --depth 1 https://github.com/HunxByts/GhostTrack.git ~/GhostTrack; \
python ~/GhostTrack/ghost.py myip >/dev/null 2>&1 && echo READY || echo "setup needed"
```

If the wrapper `~/GhostTrack/ghost.py` is absent (a fresh clone has only the interactive
`GhostTR.py`), create it once from the operator's copy, or fall back to the lookups below written
directly in Python. Prefer the wrapper when present (use `timeoutSeconds: 300` for this step).

## 2. Lookups (the wrapper)

```
python ~/GhostTrack/ghost.py myip              # your current public IP + geolocation
python ~/GhostTrack/ghost.py ip 8.8.8.8        # geolocate any IP (ipwho.is)
python ~/GhostTrack/ghost.py phone +14155552671  # carrier, region, timezone (phonenumbers)
python ~/GhostTrack/ghost.py user somehandle    # which social sites have that username
```

Add `--json` for structured output you can parse. Phone numbers need the country code (the `+`).
The username check makes ~20 web requests, so give it `timeoutSeconds: 120`.

## Reading results

- **IP**: report country, city, region, ISP and the Google Maps link. IP geolocation is accurate to
  city, not to a street; say so.
- **Phone**: carrier and region come from the number's prefix, not from a live lookup, so they show
  where the number was issued, not where the phone is now.
- **Username**: a 200 response means the profile URL exists, not that it is the same person. Treat
  matches as leads to verify, never as identity confirmation.

## Scope and honesty

Do these lookups for the operator's own accounts, their own numbers, or targets they state they are
authorised to investigate. If a request looks like it targets a private individual without a stated
authorised purpose, say so and ask before running it. Never present OSINT guesses as certainty.
