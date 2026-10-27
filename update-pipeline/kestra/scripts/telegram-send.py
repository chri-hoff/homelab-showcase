#!/usr/bin/env python3
"""Send a Telegram message from a Kestra task (Process runner, stdlib only).

    telegram-send.py "text"        or   ... | telegram-send.py
Environment: BOT_TOKEN, CHAT_ID (Kestra secret()).
Telegram accepts at most 4096 characters; longer texts keep their head and tail.
"""
import json
import os
import sys
import urllib.request

MAX = 4000

text = sys.argv[1] if len(sys.argv) > 1 else sys.stdin.read()
if len(text) > MAX:
    text = text[:1000] + "\n[...gekürzt...]\n" + text[-(MAX - 1100):]
req = urllib.request.Request(
    f"https://api.telegram.org/bot{os.environ['BOT_TOKEN']}/sendMessage",
    data=json.dumps({"chat_id": os.environ["CHAT_ID"], "text": text}).encode(),
    headers={"Content-Type": "application/json"})
with urllib.request.urlopen(req, timeout=30) as resp:
    if json.load(resp).get("ok") is not True:
        sys.exit("Telegram: ok != true")
