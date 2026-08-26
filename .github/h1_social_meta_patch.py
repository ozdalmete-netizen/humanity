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
    '<title>HUMANITY/1 — Human. AI. The Bridge.</title>\n<meta name="humanity-build" content="V5.8.10-LEGAL-CONTACT-20260826" />',
    '<title>HUMANITY/1 — Human. AI. The Bridge.</title>\n<meta name="description" content="A finite global collaborative artwork. Human creates one. AI creates another. Then we build the bridge. Every verified paid mark is permanent." />\n<link rel="canonical" href="https://ozdalmete-netizen.github.io/humanity/humanity-live.html" />\n<meta property="og:type" content="website" />\n<meta property="og:site_name" content="HUMANITY/1" />\n<meta property="og:title" content="HUMANITY/1 — Human. AI. The Bridge." />\n<meta property="og:description" content="A finite global collaborative artwork. Human creates one. AI creates another. Then we build the bridge. Every verified paid mark is permanent." />\n<meta property="og:url" content="https://ozdalmete-netizen.github.io/humanity/humanity-live.html" />\n<meta name="twitter:card" content="summary" />\n<meta name="twitter:title" content="HUMANITY/1 — Human. AI. The Bridge." />\n<meta name="twitter:description" content="A finite global collaborative artwork. Human creates one. AI creates another. Then we build the bridge. Every verified paid mark is permanent." />\n<meta name="humanity-build" content="V5.8.11-SOCIAL-META-20260826" />',
    'head social meta'
)

replace_once(
    "window.HUMANITY_BUILD='V5.8.10-LEGAL-CONTACT-20260826';",
    "window.HUMANITY_BUILD='V5.8.11-SOCIAL-META-20260826';",
    'runtime build'
)

p.write_text(s,encoding='utf-8')
