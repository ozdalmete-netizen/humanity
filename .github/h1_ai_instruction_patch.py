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
    '<meta name="humanity-build" content="V5.8.7-CRYPTO-LEGAL-20260826" />',
    '<meta name="humanity-build" content="V5.8.8-AI-GUIDE-20260826" />',
    'meta build'
)

replace_once(
    '.canvas-topline p{margin:0;color:var(--muted);font-size:13px}.canvas-status{',
    '.canvas-topline p{margin:0;color:var(--muted);font-size:13px}.ai-instruction{display:none;margin:14px 18px 16px;padding:15px 16px;border:1px solid #11110f;border-radius:16px;background:#11110f;color:#fff;box-shadow:0 12px 30px rgba(17,17,15,.14)}.ai-instruction.show{display:grid;grid-template-columns:auto minmax(0,1fr);gap:12px;align-items:start}.ai-instruction-badge{padding:7px 9px;border:1px solid rgba(255,255,255,.28);border-radius:999px;font:850 8px var(--mono);letter-spacing:.12em;white-space:nowrap}.ai-instruction strong{display:block;font-size:14px;letter-spacing:-.01em}.ai-instruction p{margin:5px 0 0;color:rgba(255,255,255,.76);font-size:10px;line-height:1.55}.canvas-status{',
    'ai instruction css'
)

replace_once(
    '<div class="canvas-topline"><div><div class="canvas-kicker" id="canvasKicker">ACT I</div><h2 id="canvasTitle">THE HUMAN CANVAS</h2><p id="canvasSubtitle">Choose any empty cell. Your color. Your decision.</p></div><div class="canvas-status"><div class="status-big" id="canvasStatusBig">SYNCING…</div><div class="status-small">MARKS REMAIN</div></div></div>',
    '<div class="canvas-topline"><div><div class="canvas-kicker" id="canvasKicker">ACT I</div><h2 id="canvasTitle">THE HUMAN CANVAS</h2><p id="canvasSubtitle">Choose any empty cell. Your color. Your decision.</p></div><div class="canvas-status"><div class="status-big" id="canvasStatusBig">SYNCING…</div><div class="status-small">MARKS REMAIN</div></div></div>\n<div class="ai-instruction" id="aiInstruction">\n  <div class="ai-instruction-badge">AI GUIDE</div>\n  <div><strong>Let AI choose the color.</strong><p>Take a screenshot of this canvas, send it to any AI, and ask: “Which color should live in my selected cell?” Then place the AI’s answer as your permanent mark.</p></div>\n</div>',
    'ai instruction html'
)

replace_once(
    "  document.getElementById('canvasSubtitle').textContent=activeWorld.subtitle;",
    "  document.getElementById('canvasSubtitle').textContent=activeWorld.subtitle;\n  document.getElementById('aiInstruction')?.classList.toggle('show',activeWorld.id==='ai');",
    'ai instruction toggle'
)

replace_once(
    "window.HUMANITY_BUILD='V5.8.7-CRYPTO-LEGAL-20260826';",
    "window.HUMANITY_BUILD='V5.8.8-AI-GUIDE-20260826';",
    'runtime build'
)

p.write_text(s,encoding='utf-8')
