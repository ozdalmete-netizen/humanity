from pathlib import Path

p=Path('humanity-live.html')
s=p.read_text(encoding='utf-8')

def replace_once(old,new,label):
    global s
    n=s.count(old)
    if n!=1:
        raise SystemExit(f'{label}: expected 1 match, found {n}')
    s=s.replace(old,new,1)

replace_once(
    '<meta name="humanity-build" content="V5.8.8-AI-GUIDE-20260826" />',
    '<meta name="humanity-build" content="V5.8.9-AI-GUIDE-COPY-20260826" />',
    'meta build'
)

replace_once(
    'Take a screenshot of this canvas, send it to any AI, and ask: “Which color should live in my selected cell?” Then place the AI’s answer as your permanent mark.',
    'Select an empty cell, take a screenshot of this canvas, and send it to any AI. Ask: “Which color should live in my selected cell?” Then place the AI’s answer as your permanent mark.',
    'ai guide copy'
)

replace_once(
    "window.HUMANITY_BUILD='V5.8.8-AI-GUIDE-20260826';",
    "window.HUMANITY_BUILD='V5.8.9-AI-GUIDE-COPY-20260826';",
    'runtime build'
)

p.write_text(s,encoding='utf-8')
