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
    '<meta name="humanity-build" content="V5.8.9-AI-GUIDE-COPY-20260826" />',
    '<meta name="humanity-build" content="V5.8.10-LEGAL-CONTACT-20260826" />',
    'meta build'
)

replace_once(
    '<div class="legal-warning">Before live sales begin, HUMANITY/1 will publish a dedicated legal/privacy contact address. No contact address has been invented or inserted into this build.</div>',
    '<div class="legal-callout"><b>Legal &amp; privacy contact:</b> <a href="mailto:ozdalmete@gmail.com">ozdalmete@gmail.com</a></div>',
    'terms contact'
)

replace_once(
    '<div class="legal-warning">A dedicated HUMANITY/1 privacy contact address must be added before live sales are enabled. This build intentionally does not invent one.</div>',
    '<div class="legal-callout"><b>Privacy contact:</b> <a href="mailto:ozdalmete@gmail.com">ozdalmete@gmail.com</a></div>',
    'privacy contact'
)

replace_once(
    '<p>A mark is a permanent placement and verification record inside HUMANITY/1. It is not an investment, security, deposit, cryptocurrency, NFT, equity interest, or transfer of copyright in the underlying artwork.</p>',
    '<p>A mark is a permanent placement and verification record inside HUMANITY/1. It is not an investment, security, deposit, cryptocurrency, NFT, equity interest, or transfer of copyright in the underlying artwork.<br>Legal &amp; privacy contact: <a href="mailto:ozdalmete@gmail.com">ozdalmete@gmail.com</a></p>',
    'footer contact'
)

replace_once(
    "window.HUMANITY_BUILD='V5.8.9-AI-GUIDE-COPY-20260826';",
    "window.HUMANITY_BUILD='V5.8.10-LEGAL-CONTACT-20260826';",
    'runtime build'
)

p.write_text(s,encoding='utf-8')
